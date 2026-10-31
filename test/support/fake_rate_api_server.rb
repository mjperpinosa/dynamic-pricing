require "socket"

# A local HTTP server standing in for rate-api, so tests run the real client (HTTParty, sockets,
# timeouts) without calling the real model, whose every call counts against the daily quota.
class FakeRateApiServer
  Request = Data.define(:http_method, :path, :headers, :body)

  # Each response is a hash with :status and :body, and optionally :content_type, :delay (seconds to
  # wait before answering) and :drop (close the connection without answering). The nth request gets
  # the nth response; once they run out, the last one is repeated.
  def initialize(*responses)
    @responses = responses
    @requests = []
    @handlers = []
    @mutex = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @acceptor = Thread.new { accept_connections }
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  # The requests received so far, oldest first.
  def requests
    @mutex.synchronize { @requests.dup }
  end

  def close
    @server.close
    @acceptor.join(1)
    @mutex.synchronize { @handlers.dup }.each(&:kill)
  end

  private

  def accept_connections
    loop do
      socket = @server.accept
      @mutex.synchronize { @handlers << Thread.new { handle(socket) } }
    end
  rescue IOError, SystemCallError
    # the server was closed
  end

  def handle(socket)
    request = read_request(socket) or return
    response = @mutex.synchronize do
      @requests << request
      @responses[[@requests.size, @responses.size].min - 1]
    end

    sleep response.fetch(:delay, 0)
    return if response[:drop]

    body = response.fetch(:body, "")
    socket.write "HTTP/1.1 #{response.fetch(:status)} Fake\r\n" \
                 "Content-Type: #{response.fetch(:content_type, 'application/json')}\r\n" \
                 "Content-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n" \
                 "\r\n" \
                 "#{body}"
  rescue IOError, SystemCallError
    # the client gave up first, e.g. after its read timeout
  ensure
    socket.close
  end

  def read_request(socket)
    request_line = socket.gets or return
    http_method, path = request_line.split
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.strip
    end
    Request.new(http_method:, path:, headers:, body: socket.read(headers["content-length"].to_i))
  end
end
