#!/usr/bin/env ruby
# frozen_string_literal: true

# Genera DinasDriver.xcodeproj (target de app iOS universal + target de tests) sobre
# el código en DinasDriver/. GRDB se integra como paquete SPM remoto.
#
# Reproducible: borra y regenera el .xcodeproj. Fuente de verdad del proyecto Xcode.
#
#   ruby Scripts/generate_project.rb
#
# Requiere la gema `xcodeproj` (gem install --user-install xcodeproj).

require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'DinasDriver.xcodeproj')
DEPLOYMENT_TARGET = '16.0'
BUNDLE_ID = 'com.dinas.driver'
GRDB_URL = 'https://github.com/groue/GRDB.swift.git'
GRDB_MIN_VERSION = '6.29.0'

# --- Proyecto -----------------------------------------------------------------

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

# Grupos que apuntan a las carpetas reales.
app_group = project.new_group('DinasDriver', 'DinasDriver')
tests_group = project.new_group('DinasDriverTests', 'DinasDriverTests')
config_group = project.new_group('Config', 'Config')

# xcconfig por ambiente. Debug->Dev, Staging->Staging, Release->Prod.
config_group.new_file(File.join(ROOT, 'Config', 'Base.xcconfig'))
xcconfig_ref = {
  'Debug'   => config_group.new_file(File.join(ROOT, 'Config', 'Dev.xcconfig')),
  'Staging' => config_group.new_file(File.join(ROOT, 'Config', 'Staging.xcconfig')),
  'Release' => config_group.new_file(File.join(ROOT, 'Config', 'Prod.xcconfig'))
}

# Añade una configuración 'Staging' (clon de Release) a project + targets.
def add_staging(obj, project)
  release = obj.build_configuration_list['Release']
  staging = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  staging.name = 'Staging'
  staging.build_settings = release.build_settings.dup
  obj.build_configuration_list.build_configurations << staging
end

# --- Paquete SPM: GRDB --------------------------------------------------------

pkg_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
pkg_ref.repositoryURL = GRDB_URL
pkg_ref.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => GRDB_MIN_VERSION }
project.root_object.package_references << pkg_ref

grdb_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
grdb_dep.package = pkg_ref
grdb_dep.product_name = 'GRDB'

# --- Target de app ------------------------------------------------------------

app = project.new_target(:application, 'DinasDriver', :ios, DEPLOYMENT_TARGET)

# Fuentes .swift bajo DinasDriver/ (excepto recursos).
Dir.glob(File.join(ROOT, 'DinasDriver', '**', '*.swift')).sort.each do |path|
  ref = app_group.new_file(path)
  app.add_file_references([ref])
end

# Info.plist por ambiente (INFOPLIST_FILE lo elige cada .xcconfig). Solo referencias.
app_group.new_file(File.join(ROOT, 'DinasDriver', 'Resources', 'Info.plist'))
app_group.new_file(File.join(ROOT, 'DinasDriver', 'Resources', 'Info-Dev.plist'))
app_group.new_file(File.join(ROOT, 'DinasDriver', 'Resources', 'DinasDriver.entitlements'))

# Asset catalog (icono de la app) como recurso.
assets_ref = app_group.new_file(File.join(ROOT, 'DinasDriver', 'Resources', 'Assets.xcassets'))
app.add_resources([assets_ref])

# GRDB como dependencia del target de app.
app.package_product_dependencies << grdb_dep
grdb_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
grdb_build_file.product_ref = grdb_dep
app.frameworks_build_phase.files << grdb_build_file

app.build_configurations.each do |config|
  s = config.build_settings
  # PRODUCT_BUNDLE_IDENTIFIER llega del .xcconfig (varía por ambiente).
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['MARKETING_VERSION'] = '0.1.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  # INFOPLIST_FILE llega del .xcconfig (Info.plist en Prod/Staging; Info-Dev.plist en Dev).
  s['CODE_SIGN_ENTITLEMENTS'] = 'DinasDriver/Resources/DinasDriver.entitlements'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['TARGETED_DEVICE_FAMILY'] = '1'          # iPhone only (el driver anda en la calle)
  s['SWIFT_VERSION'] = '5.0'
  s['DEVELOPMENT_LANGUAGE'] = 'es'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['ENABLE_PREVIEWS'] = 'YES'
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  # MIDDLEWARE_BASE_URL, APP_DISPLAY_NAME y DEVELOPMENT_TEAM llegan del .xcconfig.
end

# Staging para project + app, y enlace de cada configuración a su .xcconfig.
add_staging(project, project)
add_staging(app, project)
app.build_configurations.each do |config|
  ref = xcconfig_ref[config.name]
  config.base_configuration_reference = ref if ref
end

# --- Target de tests ----------------------------------------------------------

tests = project.new_target(:unit_test_bundle, 'DinasDriverTests', :ios, DEPLOYMENT_TARGET)
Dir.glob(File.join(ROOT, 'DinasDriverTests', '**', '*.swift')).sort.each do |path|
  ref = tests_group.new_file(path)
  tests.add_file_references([ref])
end
tests.add_dependency(app)
tests.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{BUNDLE_ID}.tests"
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['SWIFT_VERSION'] = '5.0'
  s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/DinasDriver.app/DinasDriver'
  s['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
add_staging(tests, project)

# --- Esquema ------------------------------------------------------------------

project.save

# Esquema de DESARROLLO (default de Cmd+R): Run/Test en Debug → Dev.xcconfig.
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(tests)
scheme.save_as(PROJECT_PATH, 'DinasDriver', true)

# Esquema de PRODUCCIÓN — opción APARTE y seleccionable, NO el default. Todas sus acciones usan
# la configuración Release (→ Prod.xcconfig: HTTPS a wms-api.dinascorp.com). El scheme de dev
# de arriba queda intacto, así que Cmd+R diario sigue apuntando a Dev.
prod = Xcodeproj::XCScheme.new
prod.add_build_target(app)
prod.set_launch_target(app)
prod.add_test_target(tests)
prod.launch_action.build_configuration = 'Release'
prod.test_action.build_configuration = 'Release'
prod.profile_action.build_configuration = 'Release'
prod.analyze_action.build_configuration = 'Release'
prod.archive_action.build_configuration = 'Release'
prod.save_as(PROJECT_PATH, 'DinasDriver (Prod)', true)

puts "Generado #{PROJECT_PATH}"
