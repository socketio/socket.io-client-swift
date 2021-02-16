Pod::Spec.new do |s|
  s.name         = "Socket.IO-Client-Swift"
  s.module_name  = "SocketIO"
  s.version      = "16.0.1"
  s.summary      = "Socket.IO-client for iOS and OS X"
  s.description  = <<-DESC
                   Socket.IO-client for iOS and OS X.
                   Supports ws/wss/polling connections and binary.
                   For socket.io 3.0+ and Swift.
                   DESC
  s.homepage     = "https://github.com/socketio/socket.io-client-swift"
  s.license      = { :type => 'MIT' }
  s.author       = { "Erik" => "nuclear.ace@gmail.com" }
  s.ios.deployment_target = '10.0'
  s.osx.deployment_target = '10.13'
  s.tvos.deployment_target = '10.0'
  s.watchos.deployment_target = '5.0'
  s.requires_arc = true
  s.source = {
    :git => "https://github.com/socketio/socket.io-client-swift.git",
    :tag => 'v16.0.1',
    :submodules => true
  }

  s.swift_version = "5"
  s.pod_target_xcconfig = {
      'SWIFT_VERSION' => '5.0'
  }
  s.source_files  = "Source/SocketIO/**/*.swift", "Source/SocketIO/*.swift"
  s.dependency "Starscream", "~> 4.0"
end
