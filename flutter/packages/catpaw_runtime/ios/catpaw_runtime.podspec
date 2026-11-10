Pod::Spec.new do |s|
  s.name = 'catpaw_runtime'
  s.version = '0.1.0'
  s.summary = 'On-device Node runtime bridge for imported CatPaw subscriptions.'
  s.homepage = 'https://github.com/Pilipala9919/MarcoMovie'
  s.license = { :type => 'GPL-3.0-only', :file => '../../../../LICENSE' }
  s.author = { 'Pilipala' => '' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.vendored_frameworks = 'Frameworks/NodeMobile.xcframework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'ENABLE_BITCODE' => 'NO',
    # The bridge itself calls node_start; linking only the final Runner is too late.
    'OTHER_LDFLAGS' => '$(inherited) -framework NodeMobile',
  }
end
