# frozen_string_literal: true

require 'redis'

require_relative 'redis_cluster/cluster'
require_relative 'redis_cluster/client'
require_relative 'redis_cluster/future'
require_relative 'redis_cluster/function'
require_relative 'redis_cluster/middlewares'

# RedisCluster is a client for redis-cluster *huh*
class RedisCluster
  include MonitorMixin
  include Function

  attr_reader :cluster, :cluster_opts, :redis_opts, :middlewares

  def initialize(seeds, redis_opts: nil, cluster_opts: nil)
    @cluster_opts = cluster_opts || {}
    @redis_opts = redis_opts || {}
    @middlewares = Middlewares.new

    client_creater = method(:create_client)
    @cluster = Cluster.new(seeds, cluster_opts, &client_creater)

    super()
  end

  def logger
    cluster_opts[:logger]
  end

  def silent?
    cluster_opts[:silent]
  end

  def connected?
    cluster.connected?
  end

  def close
    safely{ cluster.close }
  end

  def pipeline?
    !@pipeline.nil?
  end

  def call(*args, &block)
    middlewares.invoke(:call, self, *args) do
      _call(*args, &block)
    end
  end

  def pipelined(*args, &block)
    middlewares.invoke(:pipelined, self, *args) do
      _pipelined(*args, &block)
    end
  end

  private

  NOOP = ->(v){ v }

  def _call(keys, command, opts = {})
    opts[:transform] ||= NOOP
    slot = cluster.slot_for(keys)

    safely do
      if pipeline?
        call_pipeline(slot, command, opts)
      else
        call_immediately(slot, command, opts)
      end
    end
  end

  def _pipelined
    safely do
      return yield if pipeline?

      begin
        @pipeline = []
        yield

        try = 3
        while !@pipeline.empty? && try.positive?
          try -= 1
          moved = false
          mapped_future = map_pipeline(@pipeline)

          @pipeline = []
          mapped_future.each do |url, futures|
            leftover, error = do_pipelined(url, futures)
            moved ||= (error == :moved || error == :down)

            @pipeline.concat(leftover)
          end

          cluster.reset if moved
        end

        @pipeline.first.value unless @pipeline.empty?
      ensure
        @pipeline = nil
      end
    end
  end

  def safely
    synchronize{ yield } if block_given?
  rescue StandardError => e
    logger&.error(e)
    raise e unless silent?
  end

  def call_immediately(slot, command, transform:, read: false)
    try = 3
    asking = false
    reply = nil
    mode = read ? :read : :write
    client = cluster.client_for(mode, slot)

    while try.positive?
      begin
        try -= 1

        client.push([:asking]) if asking
        reply = client.call(command)

        err, url = scan_reply(reply)
        return transform.call(reply) unless err

        cluster.reset if err == :moved
        asking = err == :ask
        client = cluster[url]
      rescue LoadingStateError, Redis::CannotConnectError => e
        if e.is_a?(Redis::CannotConnectError)
          asking = false
          cluster.reset
        end
        client = cluster.client_for(mode, slot)
        reply = e
      end
    end

    raise reply
  end

  def call_pipeline(slot, command, opts)
    Future.new(slot, command, opts[:transform]).tap do |future|
      @pipeline << future
    end
  end

  def map_pipeline(pipe)
    futures = ::Hash.new{ |h, k| h[k] = [] }
    pipe.each do |future|
      url = future.url || cluster.client_for(:write, future.slot).url
      futures[url] << future
    end

    futures
  end

  def do_pipelined(url, futures)
    error = nil
    leftover = []

    rev_index = {}
    idx = 0
    client = cluster[url]

    futures.each_with_index do |future, i|
      if future.asking
        client.push([:asking])
        idx += 1
      end

      rev_index[idx] = i
      client.push(future.command)
      idx += 1
    end

    client.commit.each_with_index do |reply, i|
      next unless rev_index[i]

      future = futures[rev_index[i]]
      future.value = reply

      err, url = scan_reply(reply)
      next unless err

      error ||= :moved if err == :moved
      future.asking = err == :ask
      future.url = url
      leftover << future
    end

    [leftover, error]
  rescue LoadingStateError, Redis::CannotConnectError => e
    # reset url and asking when connection refused
    futures.each{ |f| f.url = nil; f.asking = false }

    [futures, e.is_a?(LoadingStateError) ? :loading : :down]
  end

  def scan_reply(reply)
    if reply.is_a?(Redis::CommandError)
      err, _slot, url = reply.to_s.split
      raise reply if err != 'MOVED' && err != 'ASK'

      [err.downcase.to_sym, url]
    elsif reply.is_a?(::RuntimeError)
      raise reply
    end
  end

  def create_client(url)
    host, port = url.split(':', 2)
    Client.new(redis_opts.merge(host: host, port: port)).tap do |c|
      c.middlewares = middlewares
    end
  end
end
