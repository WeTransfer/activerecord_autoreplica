# The idea is this: we can have ActiveRecord::Base.connection return an Adapter object (that executes the
# actual SQL queries) and inside that adapter we can redirect all SELECT queries to the read replica instead of
# the main database. This is however slightly more involved than it looks, because if we keep calling
# establish_connection willy-nilly we are going to disconnect from the master DB, connect to the read DB, disconnect
# again and so on.
#
# The right approach for this is to maintain a separate connection pool instad just for connections to the read
# slave. This is exactly what we are doing within AutoReplica.
#
# The setup to make it work is a bit involved. If you want to play with how ActiveRecord uses connections,
# the only actual "official" hook you can use is replacing the connection handler it uses. When a SQL request needs
# to be run AR walks the following dependency chain to arrive at the actual connection:
#
# * SomeRecord.connection calls ActiveRecord::Base.connection_handler
# * It then asks the connection handler for a connection for this specific ActiveRecord subclass, or barring that
#   - for the connection for one of it's ancestors, ending with ActiveRecord::Base itself
# * The ConnectionHandler, in turn, asks one of its managed ConnectionPool objects to give it a connection for use.
# * The connection is returned and then the query is ran against it.
#
# This is why the only integration point for this is ++ActiveRecord::Base.connection_handler=++
# To make our trick work, here is what we do:
#
# First we wrap the original ConnectionHandler used by ActiveRecord in our own proxy. That proxy will ask the original
# ConnectionHandler for a connection to use, but it will also maintain it's own ConnectionPool just for the read
# replica connections.
#
# When a connection is returned by the original Handler, it is wrapped into a Adapter together with the
# read connection obtained from the special read pool. That proxy will intercept all of the SQL methods for SELECT
# and redirect them to the read connection instead. All of the other methods (including transactions)
# are still going to be executed on the master database.
#
# Once the block exits, the original connection handler is reassigned to the AR connection_pool.
module AutoReplica

  # The first one is used in ActiveRecord 3+, the second one in 4+
  ConnectionSpecification = begin
    ActiveRecord::Base::ConnectionSpecification
  rescue
    ActiveRecord::ConnectionAdapters::ConnectionSpecification
  end

  def self.connection_set_up?; @connection_set_up; end
  def self.connection_set_up!; @connection_set_up = true; end

  def self.current_read_pool
    Thread.current[:autoreplica_read_pool]
  end

  def self.current_read_pool=(pool)
    Thread.current[:autoreplica_read_pool] = pool
  end

  def self.clear_current_read_pool
    Thread.current[:autoreplica_read_pool] = nil
  end

  # Runs a given block with all SELECT statements being executed against the read slave
  # database.
  #
  #     AutoReplica.using_read_replica_at(:adapter => 'mysql2', :database => 'read_replica', ...) do
  #       customer = Customer.find(3) # Will SELECT from the replica database at the connection spec passed to the block
  #       customer.register_complaint! # Will UPDATE to the master database connection
  #     end
  #
  # @param replica_connection_spec_hash_or_url[String, Hash] an ActiveRecord connection specification or a DSN URL
  # @return [void]
  def self.using_read_replica_at(replica_connection_spec_hash_or_url)
    read_pool = get_pool(replica_connection_spec_hash_or_url)
    begin
      in_replica_context(read_pool){ yield }
    ensure
      read_pool.disconnect!
    end
  end

  # Runs a given block with all SELECT statements being executed using the read slave
  # connection pool.
  #
  #     read_pool = ActiveRecord::ConnectionAdapters::ConnectionPool.new(:adapter => 'mysql2', :database => 'read_replica', ...)
  #     AutoReplica.using_read_replica_pool(read_pool) do
  #       customer = Customer.find(3) # Will SELECT from the replica database picked off the read pool
  #       customer.register_complaint! # Will UPDATE to the master database connection
  #     end
  #
  # @param replica_connection_pool[ActiveRecord::ConnectionAdapters::ConnectionPool] an ActiveRecord connection pool instance
  # @return [void]
  def self.using_read_replica_pool(replica_connection_pool)
    in_replica_context(replica_connection_pool){ yield }
  end

  def self.in_replica_context(read_pool)
    return yield if current_read_pool # This method should not be reentrant

    # There is a pontential race condition here in a threaded environment, but
    # in the worst case the handler will be set up twice. This shouldn't affect
    # operations.
    unless connection_set_up?
      original_connection_handler = ActiveRecord::Base.connection_handler
      custom_handler = AutoReplica::ConnectionHandler.new(original_connection_handler)
      ActiveRecord::Base.connection_handler = custom_handler
      connection_set_up!
    end

    begin
      self.current_read_pool = read_pool
      yield
    ensure
      custom_handler.finish_read_context
      clear_current_read_pool
    end
  end

  def self.get_pool(replica_connection_spec_hash_or_url)
      connection_specification_hash = parse_params(replica_connection_spec_hash_or_url)
      # We need to maintain our own pool for read replica connections,
      # aside from the one managed by Rails proper.
      adapter_method = "%s_connection" % connection_specification_hash[:adapter]
      connection_specification = begin
        ConnectionSpecification.new('autoreplica', connection_specification_hash, adapter_method)
      rescue ArgumentError # AR 4 and lower wants 2 arguments
        ConnectionSpecification.new(connection_specification_hash, adapter_method)
      end
      ActiveRecord::ConnectionAdapters::ConnectionPool.new(connection_specification)
    end

    def self.parse_params(replica_connection_spec_hash_or_url)
      # Resolve if there is a URL given
      # Duplicate the hash so that we can change it if we have to
      # (say by deleting :adapter)
      if replica_connection_spec_hash_or_url.is_a?(Hash)
        replica_connection_spec_hash_or_url.dup
      else
        resolve_connection_url(replica_connection_spec_hash_or_url).dup
      end
    end

    # Resolve an ActiveRecord connection URL, from a string to a Hash.
    #
    # @param url_string[String] the connection URL (like `sqlite3://...`)
    # @return [Hash] a symbol-keyed ActiveRecord connection specification
    def self.resolve_connection_url(url_string)
      # TODO: privatize this method.
      if defined?(ActiveRecord::Base::ConnectionSpecification::Resolver) # AR3
        resolver = ActiveRecord::Base::ConnectionSpecification::Resolver.new(url_string, {})
        resolver.send(:connection_url_to_hash, url_string) # Because making this public was so hard
      else  # AR4
        resolved = ActiveRecord::ConnectionAdapters::ConnectionSpecification::ConnectionUrlResolver.new(url_string).to_hash
        resolved["database"].gsub!(/^\//, '') # which is not done by the resolver
        resolved.symbolize_keys # which is also not done by the resolver
      end
    end

  # The connection handler that wraps the ActiveRecord one. Everything gets forwarded to the wrapped
  # object, but a "spiked" connection adapter gets returned from retrieve_connection.
  class ConnectionHandler # a proxy for ActiveRecord::ConnectionAdapters::ConnectionHandler
    def initialize(original_handler)
      @original_handler = original_handler
    end

    # Overridden method which gets called by ActiveRecord to get a connection related to a specific
    # ActiveRecord::Base subclass.
    def retrieve_connection(for_ar_class)
      # See which thread is calling us. If it is the thread that initiated the `in_replica_context`
      # block, we return a wrapper proxy. If it is not, then it is a different thread willing to
      # use a connection, and we have to give it the original adapter instead
      if read_pool = AutoReplica.current_read_pool
        connection_for_writes = @original_handler.retrieve_connection(for_ar_class)
        connection_for_reads = read_pool.connection
        Adapter.new(connection_for_writes, connection_for_reads)
      else
        @original_handler.retrieve_connection(for_ar_class)
      end
    end

    def release_read_pool_connection
      AutoReplica.current_read_pool.release_connection
    end

    # Close all the connections maintained by the read pool
    def disconnect_read_pool!
      AutoReplica.current_read_pool.disconnect!
    end

    # Disconnect both the original handler AND the read pool
    def clear_all_connections!
      disconnect_read_pool!
      @original_handler.clear_all_connections!
    end

    # The duo for method proxying without delegate
    def respond_to_missing?(method_name)
      @original_handler.respond_to?(method_name)
    end
    def method_missing(method_name, *args, &blk)
      @original_handler.public_send(method_name, *args, &blk)
    end

    # When finishing, releases the borrowed connection back into the pool
    def finish_read_context
      release_read_pool_connection
    end
  end

  # Acts as a wrapping proxy that replaces an ActiveRecord Adapter object. This is the
  # "connection adapter" object that ActiveRecord uses internally to run SQL queries
  # against. We let it dispatch all SELECT queries to the read replica and all
  # other queries to the master database.
  #
  # To achieve this, we make a delegator proxy that sends all methods prefixed with "select_"
  # to the read connection, and all the others to the master connection.
  class Adapter # a proxy for ActiveRecord::ConnectionAdapters::AbstractAdapter
    def initialize(master_connection_adapter, replica_connection_adapter)
      @master_connection = master_connection_adapter
      @read_connection = replica_connection_adapter
    end

    # Under the hood, ActiveRecord uses methods for the most common database statements
    # like "select_all", "select_one", "select_value" and so on. Those can be overridden by concrete
    # connection adapters, but in the basic abstract Adapter they get included from
    # DatabaseStatements. Therefore we can obtain a list of those methods (that we want to override)
    # by grepping the instance method names of the DatabaseStatements module.
    select_methods = ActiveRecord::ConnectionAdapters::DatabaseStatements.instance_methods.grep(/^select_/)
    # ...and then for each of those "select_something" methods we can make a method override
    # that will redirect the method to the read connection.
    select_methods.each do | select_method_name |
      define_method(select_method_name) do |*method_arguments|
        @read_connection.send(select_method_name, *method_arguments)
      end
    end

    # The duo for method proxying without delegate
    def respond_to_missing?(method_name)
      @master_connection.respond_to?(method_name)
    end
    def method_missing(method_name, *args, &blk)
      @master_connection.public_send(method_name, *args, &blk)
    end
  end

#  if respond_to?(:private_constant)
#    private_constant :ConnectionSpecification
#    private_constant :ConnectionHandler
#    private_constant :Adapter
#  end

end
