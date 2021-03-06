require 'xcodeproj'

# Create a list of contained projects
#  If Xcode workspace path provided it collects the included projects
#  If Xcode project path provided it returns the provided path as a singe element array
# @param project_or_workspace_pth (String): Xcode project or workspace path
# @return (Array): The contained projects
def contained_projects(project_or_workspace_pth)
  project_paths = []
  if File.extname(project_or_workspace_pth) == '.xcodeproj'
    project_paths = [project_or_workspace_pth]
  else
    workspace_contents_pth = File.join(project_or_workspace_pth, 'contents.xcworkspacedata')
    workspace_contents = File.read(workspace_contents_pth)
    project_paths = workspace_contents.scan(/\"group:(.*)\"/).collect do |current_match|
      # skip cocoapods projects
      return nil if current_match.end_with?('Pods/Pods.xcodeproj')

      File.join(File.expand_path('..', project_or_workspace_pth), current_match.first)
    end
  end
  project_paths
end

# Collects target bundle ids
# @param project_or_workspace_pth (String): Xcode project or workspace path
# @return (Hash - project_path (String) <-> bundle_ids (Array)) : bundle ids per project
def get_project_bundle_ids(project_or_workspace_pth)
  project_bundle_ids_map = {}

  project_paths = contained_projects(project_or_workspace_pth)
  project_paths.each do |project_path|
    target_bundle_ids = []

    project = Xcodeproj::Project.open(project_path)
    project.targets.each do |target|
      next if target.test_target_type?

      target.build_configuration_list.build_configurations.each do |build_configuration|
        build_settings = build_configuration.build_settings

        bundle_identifier = build_settings['PRODUCT_BUNDLE_IDENTIFIER']
        target_bundle_ids.push(bundle_identifier) unless target_bundle_ids.include?(bundle_identifier)
      end
    end

    project_bundle_ids_map[project_path] = target_bundle_ids
  end

  project_bundle_ids_map
end

# Apply code sign settings
#  Sets ProvisioningStyle to Manual
#  Sets DEVELOPMENT_TEAM, CODE_SIGN_IDENTITY and PROVISIONING_PROFILE per target
# @param project_or_workspace_pth (String): Xcode project or workspace path
# @param bundle_id_code_sing_info_map (Hash) {Hash[bundle_id][:development/:distribution]{certificate_path, certificate_passphrase, certificate, profile}}: Code sign settings
# @param development_team (String): The development team's id
def force_code_sign_properties(project_or_workspace_pth, bundle_id_code_sing_info_map, development_team)
  project_paths = contained_projects(project_or_workspace_pth)
  project_paths.each do |project_path|
    project = Xcodeproj::Project.open(project_path)
    project.targets.each do |target|
      next if target.test_target_type?

      # force manual code singing
      target_id = target.uuid
      attributes = project.root_object.attributes['TargetAttributes']
      target_attributes = attributes[target_id]
      target_attributes['ProvisioningStyle'] = 'Manual'

      # apply code sign properties
      target.build_configuration_list.build_configurations.each do |build_configuration|
        build_settings = build_configuration.build_settings

        bundle_identifier = build_settings['PRODUCT_BUNDLE_IDENTIFIER']
        code_sign_info_map = bundle_id_code_sing_info_map[bundle_identifier]

        next unless code_sign_info_map

        certificate = code_sign_info_map[:development][:certificate]
        profile = code_sign_info_map[:development][:profile]

        build_settings['DEVELOPMENT_TEAM'] = development_team
        build_settings['CODE_SIGN_IDENTITY'] = certificate.name
        build_settings['PROVISIONING_PROFILE'] = profile.uuid
      end
    end

    project.save
  end
end
