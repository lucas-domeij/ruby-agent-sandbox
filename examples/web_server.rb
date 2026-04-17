$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_sandbox"
require "net/http"

sandbox = AgentSandbox.new(backend: :docker, image: "ruby:3.3-slim", ports: [8080])

sandbox.open do |s|
  s.write_file("/workspace/server.rb", <<~RUBY)
    require "socket"
    server = TCPServer.new("0.0.0.0", 8080)
    loop do
      client = server.accept
      client.readpartial(4096) rescue nil
      body = "hello from sandbox\\n"
      client.write("HTTP/1.1 200 OK\\r\\nContent-Length: \#{body.bytesize}\\r\\nConnection: close\\r\\n\\r\\n\#{body}")
      client.close
    end
  RUBY

  s.spawn("ruby /workspace/server.rb")

  sleep 1.5
  url = s.port_url(8080)
  puts "calling #{url}"
  puts Net::HTTP.get(URI(url))
end
