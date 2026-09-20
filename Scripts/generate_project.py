#!/usr/bin/env python3
"""Deterministically generate a dependency-free Xcode project."""
from pathlib import Path
import hashlib, plistlib, json
root=Path(__file__).resolve().parents[1]
objects={}
def ident(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def add(key, isa, **values):
    i=ident(key); objects[i]=dict(isa=isa,**values); return i
def fmt(x,depth=0):
    if isinstance(x,dict):return '{\n'+''.join('\t'*(depth+1)+json.dumps(k)+' = '+fmt(v,depth+1)+';\n' for k,v in x.items())+'\t'*depth+'}'
    if isinstance(x,list):return '('+', '.join(fmt(v,depth) for v in x)+')'
    if isinstance(x,int):return str(x)
    return json.dumps(x,ensure_ascii=False)
refs={}
for path in sorted(list(root.glob('DeskKit/*.swift'))+list(root.glob('Shared/*.swift'))+list(root.glob('DeskKitWidgets/*.swift'))):
    name=str(path.relative_to(root));refs[name]=add(name,'PBXFileReference',lastKnownFileType='sourcecode.swift',path=name,sourceTree='<group>')
for path,typ in [('Plugins','folder'),('PluginGuide.md','net.daringfireball.markdown'),('DeskKit/Assets.xcassets','folder.assetcatalog'),('Config/Build.xcconfig','text.xcconfig'),('DeskKit/Info.plist','text.plist.xml'),('DeskKit/DeskKit.entitlements','text.plist.entitlements'),('DeskKitWidgets/Info.plist','text.plist.xml'),('DeskKitWidgets/DeskKitWidgets.entitlements','text.plist.entitlements')]:
    refs[path]=add(path,'PBXFileReference',lastKnownFileType=typ,path=path,sourceTree='<group>')
products=[];targets=[]
base={'SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'14.0','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SWIFT_STRICT_CONCURRENCY':'minimal','REGISTER_APP_GROUPS':'NO','ENABLE_HARDENED_RUNTIME':'YES','COMBINE_HIDPI_IMAGES':'YES','CURRENT_PROJECT_VERSION':'4','MARKETING_VERSION':'0.1.1'}
for name in ['DeskKitWidgets','DeskKit']:
    app=name=='DeskKit'
    product=add(name+'product','PBXFileReference',explicitFileType='wrapper.application' if app else 'wrapper.app-extension',includeInIndex=0,path=name+('.app' if app else '.appex'),sourceTree='BUILT_PRODUCTS_DIR');products.append(product)
    files=[p for p in refs if p.endswith('.swift') and (p.startswith('Shared/') or p.startswith(name+'/'))]
    builds=[add(name+p,'PBXBuildFile',fileRef=refs[p]) for p in files]
    sourcephase=add(name+'sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=builds,runOnlyForDeploymentPostprocessing=0)
    resources=[add(name+p,'PBXBuildFile',fileRef=refs[p]) for p in ['Plugins','PluginGuide.md','DeskKit/Assets.xcassets']] if app else []
    resourcephase=add(name+'resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=resources,runOnlyForDeploymentPostprocessing=0)
    frameworks=add(name+'frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)
    phases=[sourcephase,frameworks,resourcephase];deps=[]
    if app:
        proxy=add('widgetproxy','PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=ident('DeskKitWidgetstarget'),remoteInfo='DeskKitWidgets')
        deps=[add('widgetdependency','PBXTargetDependency',target=ident('DeskKitWidgetstarget'),targetProxy=proxy)]
        embed=add('embedwidget','PBXBuildFile',fileRef=ident('DeskKitWidgetsproduct'),settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
        phases.append(add('embedphase','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[embed],name='Embed App Extensions',runOnlyForDeploymentPostprocessing=0))
    configs=[]
    for mode in ['Debug','Release']:
        settings={**base,'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'$(DESKKIT_BUNDLE_ID)'+('' if app else '.widgets'),'INFOPLIST_FILE':name+'/Info.plist','CODE_SIGN_ENTITLEMENTS':name+'/'+name+'.entitlements','GENERATE_INFOPLIST_FILE':'NO','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else '', 'DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks'] if app else ['$(inherited)','@executable_path/../Frameworks','@executable_path/../../../../Frameworks']}
        if app:settings.update(ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon')
        if not app:settings.update(APPLICATION_EXTENSION_API_ONLY='YES',SKIP_INSTALL='YES',ENABLE_APP_SANDBOX='YES')
        configs.append(add(name+mode,'XCBuildConfiguration',name=mode,baseConfigurationReference=refs['Config/Build.xcconfig'],buildSettings=settings))
    cl=add(name+'configlist','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
    target=add(name+'target','PBXNativeTarget',buildConfigurationList=cl,buildPhases=phases,buildRules=[],dependencies=deps,name=name,productName=name,productReference=product,productType='com.apple.product-type.application' if app else 'com.apple.product-type.app-extension');targets.append(target)
productgroup=add('productgroup','PBXGroup',children=products,name='Products',sourceTree='<group>')
groups=[]
for prefix in ['DeskKit','Shared','DeskKitWidgets','Config']:
    groups.append(add(prefix+'group','PBXGroup',children=[v for k,v in refs.items() if k.startswith(prefix+'/')],name=prefix,sourceTree='<group>'))
main=add('maingroup','PBXGroup',children=groups+[refs['Plugins'],refs['PluginGuide.md'],productgroup],sourceTree='<group>')
projectconfigs=[add('project'+mode,'XCBuildConfiguration',name=mode,buildSettings={}) for mode in ['Debug','Release']]
projectlist=add('projectlist','XCConfigurationList',buildConfigurations=projectconfigs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
project=add('project','PBXProject',attributes={'LastUpgradeCheck':'2650','TargetAttributes':{i:{'CreatedOnToolsVersion':'26.5'} for i in targets}},buildConfigurationList=projectlist,compatibilityVersion='Xcode 14.0',developmentRegion='zh-Hans',hasScannedForEncodings=0,knownRegions=['zh-Hans','en','Base'],mainGroup=main,productRefGroup=productgroup,projectDirPath='',projectRoot='',targets=list(reversed(targets)))
proj=root/'DeskKit.xcodeproj';proj.mkdir(exist_ok=True)
(proj/'project.pbxproj').write_text('// !$*UTF8*$!\n'+fmt({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
schemes=proj/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
(schemes/'DeskKit.xcscheme').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2650" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="'''+ident('DeskKittarget')+'''" BuildableName="DeskKit.app" BlueprintName="DeskKit" ReferencedContainer="container:DeskKit.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="'''+ident('DeskKittarget')+'''" BuildableName="DeskKit.app" BlueprintName="DeskKit" ReferencedContainer="container:DeskKit.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
for name in ['DeskKit','DeskKitWidgets']:
    app=name=='DeskKit'
    info={'CFBundleDevelopmentRegion':'zh-Hans','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':name,'CFBundleDisplayName':'DeskKit','CFBundlePackageType':'APPL' if app else 'XPC!','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','LSMinimumSystemVersion':'$(MACOSX_DEPLOYMENT_TARGET)','DeskKitAppGroup':'$(DESKKIT_APP_GROUP)','NSHumanReadableCopyright':'Copyright © 2026 Andreas.'}
    if app:info.update(LSUIElement=True,NSPrincipalClass='NSApplication',CFBundleURLTypes=[{'CFBundleURLName':'$(DESKKIT_BUNDLE_ID)','CFBundleURLSchemes':['deskkit']}],NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
    else:info.update(NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'})
    (root/name/'Info.plist').write_bytes(plistlib.dumps(info))
    ent={'com.apple.security.application-groups':['$(DESKKIT_APP_GROUP)']}
    if not app:ent['com.apple.security.app-sandbox']=True
    (root/name/(name+'.entitlements')).write_bytes(plistlib.dumps(ent))
print('Generated DeskKit.xcodeproj with',len(refs),'source/resource references')
