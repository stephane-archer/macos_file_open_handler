#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint macos_file_open_handler.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'macos_file_open_handler'
  s.version          = '0.1.0'
  s.summary          = 'Receive macOS file-open events safely.'
  s.description      = <<-DESC
Receive ordered macOS file-open events and balance explicitly started
security-scoped access after asynchronous Flutter processing completes.
                       DESC
  s.homepage         = 'https://pub.dev/packages/macos_file_open_handler'
  s.license          = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author           = { 'Stéphane Archer' => '2981437+stephane-archer@users.noreply.github.com' }

  s.source           = { :path => '.' }
  s.source_files = 'macos_file_open_handler/Sources/macos_file_open_handler/**/*.swift'

  s.resource_bundles = {
    'macos_file_open_handler_privacy' => [
      'macos_file_open_handler/Sources/macos_file_open_handler/PrivacyInfo.xcprivacy'
    ]
  }

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
