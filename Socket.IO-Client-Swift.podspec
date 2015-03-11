Pod::Spec.new do |s|
  s.name         = "Socket.IO-Client-Swift"
  s.version      = "0.0.1"
  s.summary      = "Socket.IO-Client-Swift"
  s.description  = <<-DESC
                   podspec fork of the original socketio/socket.io-client-swift
                   DESC

  s.homepage     = "https://github.com/banjun/socket.io-client-swift"
  s.license      = { :type => 'MIT' }
  s.author       = { "banjun" => "banjun@gmail.com" }
  s.platform     = :ios, "8.0"
  s.source       = { :git => "https://github.com/banjun/socket.io-client-swift.git", :tag => s.version.to_s }
  
  source_files_socketrocket = ["SocketRocket/SocketRocket/*.{h,m,c}"]
  frameworks_socketrocket = %w{CFNetwork Security}
  libraries_socketrocket = %w{icucore}

  s.source_files  = ["SwiftIO/**/*.swift"] + source_files_socketrocket
  s.frameworks = frameworks_socketrocket
  s.libraries = libraries_socketrocket
end
