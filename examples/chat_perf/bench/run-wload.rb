#!/usr/bin/env ruby
# Saturating-load runner for the chat rooms: starts the server, samples
# server and loader CPU during the run, runs wload.erl, tears down.
# Every knob is an env var. Needs unsandboxed loopback networking.
#
#   N=1000 SOAK=12 SENDERS=20 PAYLOAD=1024 PACED=10 ruby run-wload.rb
#   N=1000 WAVE=100 WAVEGAP=500 SYNC=1 SOAK=12 SENDERS=20 PAYLOAD=1024 ruby run-wload.rb
require "json"
require "net/http"
require "timeout"

BENCH = File.expand_path(__dir__)
APP = ENV.fetch("APP", "chat_perf")
PORT = ENV.fetch("PORT", "3800").to_i
N = ENV.fetch("N", "1000").to_i
RUNG = ENV.fetch("RUNG", N.to_s)
PROTO = ENV.fetch("PROTO", "delta")
SENDERS = ENV.fetch("SENDERS", "20").to_i
SOAK = ENV.fetch("SOAK", "0").to_i
FLOOD = ENV.fetch("FLOOD", "200").to_i
PAYLOAD = ENV.fetch("PAYLOAD", "1024").to_i
PACED = ENV.fetch("PACED", "10").to_i
WAVE = ENV.fetch("WAVE", "0").to_i
WAVEGAP = ENV.fetch("WAVEGAP", "0").to_i
SYNC = %w[1 true yes].include?(ENV.fetch("SYNC", ""))
TIMEOUT = ENV.fetch("TIMEOUT", "600").to_i

JSON_PATH = File.join(BENCH, "results", "bench-wload-#{RUNG}.json")
ERR_PATH = File.join(BENCH, "results", "bench-wload-#{RUNG}.err")
CPU_PATH = File.join(BENCH, "results", "cpu-wload-#{RUNG}.csv")
LOG_PATH = File.join(BENCH, "results", "server-wload-#{RUNG}.log")

# macOS's default soft fd limit (256) caps server and loader well below
# 1000 connections (emfile past ~205 clients).
FD_RAISE = "ulimit -n 65536 2>/dev/null || ulimit -n 10240;".freeze

def pids_matching(pattern)
  `pgrep -f #{pattern} 2>/dev/null`.split.map(&:to_i)
end

def tree(pids)
  seen = {}
  stack = pids.dup
  until stack.empty?
    p = stack.pop
    next if seen[p]
    seen[p] = true
    `pgrep -P #{p} 2>/dev/null`.split.each { |q| stack << q.to_i }
  end
  seen.keys
end

def cpu_sum(pids)
  return 0.0 if pids.empty?
  out = `ps -o %cpu= -p #{pids.join(",")} 2>/dev/null`
  out.split.sum { |line| Float(line.strip) rescue 0.0 }
end

def listener_pids
  `lsof -ti tcp:#{PORT} -sTCP:LISTEN 2>/dev/null`.split.map(&:to_i)
end

def server_cpu
  pids = listener_pids
  pids = pids_matching("beam") if pids.empty?
  cpu_sum(tree(pids))
end

def loader_cpu
  cpu_sum(tree(pids_matching("wload.erl")))
end

def ready?
  Net::HTTP.start("127.0.0.1", PORT, open_timeout: 1, read_timeout: 1) do |h|
    h.get("/")
  end
  true
rescue StandardError
  false
end

def kill_port
  system("lsof -ti tcp:#{PORT} 2>/dev/null | xargs kill 2>/dev/null; true")
end

kill_port
sleep 1
server_log = File.open(LOG_PATH, "w")
srv = Process.spawn(
  "bash", "-c", "#{FD_RAISE} exec tey run",
  chdir: File.join(BENCH, ".."), out: server_log, err: [:child, :out]
)

begin
  ready = false
  120.times do
    if ready?
      ready = true
      break
    end
    sleep 0.5
  end
  unless ready
    Process.kill("TERM", srv) rescue nil
    abort "SERVER_FAILED_TO_START\n#{File.read(LOG_PATH)[-3000..]}"
  end

  stop = false
  server_samples = []
  loader_samples = []
  sampler = Thread.new do
    until stop
      server_samples << server_cpu
      loader_samples << loader_cpu
      sleep 0.2
    end
  end

  args = ["escript", File.join(BENCH, "wload.erl"),
          "--port", PORT.to_s, "--clients", N.to_s, "--rung", RUNG,
          "--proto", PROTO, "--senders", SENDERS.to_s,
          "--flood", FLOOD.to_s, "--payload", PAYLOAD.to_s,
          "--paced", PACED.to_s]
  args += ["--soak", SOAK.to_s] if SOAK > 0
  args += ["--wave", WAVE.to_s, "--wavegap", WAVEGAP.to_s] if WAVE > 0
  args << "--sync" if SYNC

  err_file = File.open(ERR_PATH, "w")
  # stderr streams to disk so phase logs survive even a timeout kill.
  loader = Process.spawn(
    "bash", "-c", "#{FD_RAISE} exec #{args.map { |a| "'#{a}'" }.join(" ")}",
    out: JSON_PATH, err: err_file
  )
  begin
    Timeout.timeout(TIMEOUT) { Process.wait(loader) }
  rescue Timeout::Error
    Process.kill("KILL", loader) rescue nil
    Process.wait(loader) rescue nil
    puts "WLOAD TIMED OUT after #{TIMEOUT}s (see #{ERR_PATH} for the phase log)"
  end
  err_file.close
  stop = true
  sampler.join(5)

  puts File.read(JSON_PATH).strip
  err = File.read(ERR_PATH).strip
  puts "--- loader stderr:\n#{err.last(1500)}" unless err.empty?
  begin
    d = JSON.parse(File.read(JSON_PATH).lines.last)
    fl = d["flood"] || {}
    lat = fl["per_delivery_latency_ms"] || {}
    puts "flood: fanout=#{fl["fanout_deliveries_per_s"]}/s " \
         "wall=#{fl["wall_s"]}s loss=#{fl["loss"]} " \
         "p50/p99=#{lat["p50"]}/#{lat["p99"]}ms"
  rescue StandardError => e
    puts "(unparseable output: #{e})"
  end
  unless server_samples.empty?
    puts format("server beam%%: avg=%.0f max=%.0f over %d samples",
                server_samples.sum / server_samples.size,
                server_samples.max, server_samples.size)
  end
  unless loader_samples.empty?
    puts format("loader beam%%: avg=%.0f max=%.0f over %d samples",
                loader_samples.sum / loader_samples.size,
                loader_samples.max, loader_samples.size)
  end
ensure
  stop = true rescue nil
  Process.kill("TERM", srv) rescue nil
  begin
    Timeout.timeout(5) { Process.wait(srv) } rescue nil
  rescue StandardError
    nil
  end
  begin
    Process.kill("KILL", srv) rescue nil
  rescue StandardError
    nil
  end
  kill_port
  server_log.close rescue nil
end
