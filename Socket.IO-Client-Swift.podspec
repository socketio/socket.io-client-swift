Pod::Spec.new do |s|
  s.name         = "Socket.IO-Client-Swift"
  s.module_name  = "SocketIOClientSwift"
  s.version      = "6.1.0"
  s.summary      = "Socket.IO-client for iOS and OS X"
  s.description  = <<-DESC
                   Socket.IO-client for iOS and OS X.
                   Supports ws/wss/polling connections and binary.
                   For socket.io 1.0+ and Swift.
                   DESC
  s.homepage     = "https://github.com/socketio/socket.io-client-swift"
  s.license      = { :type => 'MIT' }
  s.author       = { "Erik" => "nuclear.ace@gmail.com" }
  s.ios.deployment_target = '8.0'
  s.osx.deployment_target = '10.10'
  s.tvos.deployment_target = '9.0'
  s.source       = { :git => "https://github.com/socketio/socket.io-client-swift.git", :tag => 'v6.1.0' }
  s.source_files  = "Source/**/*.swift"
  s.requires_arc = true
  # s.dependency 'Starscream', '~> 0.9' # currently this repo includes Starscream swift files
end
