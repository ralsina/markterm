require "./spec_helper"
require "http/server"
require "socket"
require "openssl"

# 1x1 transparent PNG, small enough to embed and large enough to sniff.
PIXEL_PNG = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")

# Sets env vars for the block (a nil value deletes), restoring the
# previous state afterwards — proxy specs must not leak HTTP_PROXY
# into the rest of the suite.
def with_proxy_env(values : Hash(String, String?), &)
  saved = values.keys.map { |name| {name, ENV[name]?} }
  values.each do |name, value|
    ENV[name] = value
  end
  yield
ensure
  saved.try &.each do |name, value|
    ENV[name] = value
  end
end

def cleared_proxy_env
  {
    "http_proxy" => nil, "HTTP_PROXY" => nil,
    "https_proxy" => nil, "HTTPS_PROXY" => nil,
    "all_proxy" => nil, "ALL_PROXY" => nil,
    "no_proxy" => nil, "NO_PROXY" => nil,
    "SSL_CERT_FILE" => nil,
  }
end

describe "Markd::Pdf.proxy_for" do
  it "selects the proxy matching the target scheme" do
    with_proxy_env(cleared_proxy_env.merge({
      "HTTP_PROXY"  => "http://10.0.0.1:3128",
      "HTTPS_PROXY" => "http://10.0.0.2:3128",
    })) do
      Markd::Pdf.proxy_for(URI.parse("http://example.com/a.png")).to_s.should eq("http://10.0.0.1:3128")
      Markd::Pdf.proxy_for(URI.parse("https://example.com/a.png")).to_s.should eq("http://10.0.0.2:3128")
    end
  end

  it "falls back to ALL_PROXY for either scheme" do
    with_proxy_env(cleared_proxy_env.merge({"ALL_PROXY" => "http://10.0.0.3:3128"})) do
      Markd::Pdf.proxy_for(URI.parse("http://example.com/a.png")).to_s.should eq("http://10.0.0.3:3128")
      Markd::Pdf.proxy_for(URI.parse("https://example.com/a.png")).to_s.should eq("http://10.0.0.3:3128")
    end
  end

  it "prefers the lowercase spelling when both are set" do
    with_proxy_env(cleared_proxy_env.merge({
      "http_proxy" => "http://10.0.0.4:3128",
      "HTTP_PROXY" => "http://10.0.0.5:3128",
    })) do
      Markd::Pdf.proxy_for(URI.parse("http://example.com/a.png")).to_s.should eq("http://10.0.0.4:3128")
    end
  end

  it "treats a bare host:port as an http proxy and keeps credentials" do
    with_proxy_env(cleared_proxy_env.merge({"http_proxy" => "user:pass@proxy:3128"})) do
      Markd::Pdf.proxy_for(URI.parse("http://example.com/a.png")).to_s.should eq("http://user:pass@proxy:3128")
    end
  end

  it "ignores non-http proxy URLs, leaving the fetch direct" do
    with_proxy_env(cleared_proxy_env.merge({"ALL_PROXY" => "socks5://10.0.0.6:1080"})) do
      Markd::Pdf.proxy_for(URI.parse("https://example.com/a.png")).should be_nil
    end
  end

  it "returns nil without any proxy environment" do
    with_proxy_env(cleared_proxy_env) do
      Markd::Pdf.proxy_for(URI.parse("https://example.com/a.png")).should be_nil
      Markd::Pdf.proxy_for(URI.parse("ftp://example.com/a.png")).should be_nil
      Markd::Pdf.proxy_for(URI.parse("http:///no-host.png")).should be_nil
    end
  end

  it "honors NO_PROXY for exact hosts, suffixes, ports and *" do
    with_proxy_env(cleared_proxy_env.merge({
      "HTTP_PROXY" => "http://10.0.0.7:3128",
      "no_proxy"   => "exact.test,.suffix.test,other.test:8080",
    })) do
      proxy = Markd::Pdf.proxy_for(URI.parse("http://exact.test/a.png"))
      proxy.should be_nil
      Markd::Pdf.proxy_for(URI.parse("http://www.suffix.test/a.png")).should be_nil
      Markd::Pdf.proxy_for(URI.parse("http://suffix.test/a.png")).should be_nil
      # Port-specific entries only exempt matching ports.
      Markd::Pdf.proxy_for(URI.parse("http://other.test:8080/a.png")).should be_nil
      Markd::Pdf.proxy_for(URI.parse("http://other.test/a.png")).to_s.should eq("http://10.0.0.7:3128")
      # Anything else still goes through the proxy.
      Markd::Pdf.proxy_for(URI.parse("http://elsewhere.test/a.png")).to_s.should eq("http://10.0.0.7:3128")
    end

    with_proxy_env(cleared_proxy_env.merge({"HTTP_PROXY" => "http://10.0.0.7:3128", "NO_PROXY" => "*"})) do
      Markd::Pdf.proxy_for(URI.parse("http://anything.test/a.png")).should be_nil
    end
  end
end

describe "Markd::Pdf proxied image fetches" do
  it "fetches plain-http images through an HTTP proxy in absolute form, with credentials" do
    requests = [] of {String, String?}
    proxy_server = HTTP::Server.new do |context|
      requests << {context.request.resource, context.request.headers["Proxy-Authorization"]?}
      if context.request.resource.ends_with?("moved.png")
        context.response.content_type = "image/png"
        context.response.write(PIXEL_PNG)
      else
        # Relative Location: exercising redirect resolution through the proxy.
        context.response.status = :found
        context.response.headers["Location"] = "moved.png"
      end
    end
    proxy_address = proxy_server.bind_tcp("127.0.0.1", 0)
    spawn { proxy_server.listen }

    converted = [] of String
    begin
      with_proxy_env(cleared_proxy_env.merge({
        "HTTP_PROXY" => "http://user:secret@#{proxy_address.address}:#{proxy_address.port}",
      })) do
        html = %(<img src="http://images.example.test/pixel.png" alt="x">)
        rewritten = Markd::Pdf.process_images(html, ".", Dir.tempdir, converted)
        rewritten.should_not eq(html)
        rewritten.should contain("img0.png")
        converted.each { |path| File.file?(path).should be_true }
      end

      # Both hops went through the proxy as absolute-form requests...
      requests.size.should eq(2)
      requests[0][0].should eq("http://images.example.test/pixel.png")
      requests[1][0].should eq("http://images.example.test/moved.png")
      # ...carrying the proxy credentials from the URL.
      expected_auth = "Basic #{Base64.strict_encode("user:secret")}"
      requests.each { |_, auth| auth.should eq(expected_auth) }
    ensure
      converted.each { |path| File.delete?(path) }
      proxy_server.close
    end
  end

  it "tunnels https image fetches through a CONNECT proxy" do
    openssl = Process.find_executable("openssl")
    pending!("openssl CLI not available to mint a test certificate") unless openssl

    cert_dir = File.tempname("markpdf-proxy-spec", "")
    Dir.mkdir(cert_dir)
    cert_path = File.join(cert_dir, "cert.pem")
    key_path = File.join(cert_dir, "key.pem")
    mint_certificate(openssl, cert_path, key_path).should be_true

    tls_context = OpenSSL::SSL::Context::Server.new
    tls_context.certificate_chain = cert_path
    tls_context.private_key = key_path

    target_requests = [] of String
    target_server = HTTP::Server.new do |context|
      target_requests << context.request.resource
      context.response.content_type = "image/png"
      context.response.write(PIXEL_PNG)
    end
    target_address = target_server.bind_tls("127.0.0.1", 0, tls_context)
    spawn { target_server.listen }

    connect_targets = [] of String
    proxy_listener = TCPServer.new("127.0.0.1", 0)
    spawn do
      while client = proxy_listener.accept?
        spawn do
          request = HTTP::Request.from_io(client)
          next unless request.is_a?(HTTP::Request) && request.method == "CONNECT"
          connect_targets << request.resource
          origin = TCPSocket.new("127.0.0.1", target_address.port)
          client << "HTTP/1.1 200 Connection Established\r\n\r\n"
          client.flush
          relay(client, origin)
        end
      end
    end

    converted = [] of String
    begin
      with_proxy_env(cleared_proxy_env.merge({
        "HTTPS_PROXY"   => "http://127.0.0.1:#{proxy_listener.local_address.port}",
        "SSL_CERT_FILE" => cert_path,
      })) do
        html = %(<img src="https://localhost:#{target_address.port}/pixel.png" alt="x">)
        rewritten = Markd::Pdf.process_images(html, ".", Dir.tempdir, converted)
        rewritten.should_not eq(html)
        rewritten.should contain("img0.png")
      end

      # The proxy saw a CONNECT for the origin, the origin saw the GET.
      connect_targets.should eq(["localhost:#{target_address.port}"])
      target_requests.should eq(["/pixel.png"])
    ensure
      converted.each { |path| File.delete?(path) }
      proxy_listener.close
      target_server.close
      File.delete?(cert_path)
      File.delete?(key_path)
      Dir.delete?(cert_dir)
    end
  end
end

# Copies bytes between two sockets until both sides are done, closing
# the pair so the tunneled client sees EOF when the origin hangs up.
private def relay(client : IO, origin : IO)
  spawn do
    IO.copy(client, origin)
  ensure
    origin.close rescue nil
  end
  begin
    IO.copy(origin, client)
  ensure
    client.close rescue nil
  end
end

# Mints a throwaway self-signed certificate for localhost; the client
# verifies tunnel TLS as always, trusting only this cert via
# SSL_CERT_FILE.
private def mint_certificate(openssl : String, cert_path : String, key_path : String) : Bool
  Process.run(openssl, [
    "req", "-x509", "-newkey", "rsa:2048",
    "-keyout", key_path, "-out", cert_path,
    "-days", "2", "-nodes",
    "-subj", "/CN=localhost",
    "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
  ], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
end
