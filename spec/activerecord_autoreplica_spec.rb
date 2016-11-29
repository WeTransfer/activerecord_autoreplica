require_relative 'helper'
require 'securerandom'

describe AutoReplica do

  before :all do
    test_seed_name = SecureRandom.hex(4)
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ('master_db_%s.sqlite3' % test_seed_name), pool: 10)

    # Setup the master and replica connections
    @master_connection_config = ActiveRecord::Base.connection_config.dup
    @replica_connection_config = @master_connection_config.merge(database: ('replica_db_%s.sqlite3' % test_seed_name), pool: 10)
    @replica_connection_config_url = 'sqlite3:/replica_db_%s.sqlite3?pool=10' % test_seed_name

    ActiveRecord::Migration.suppress_messages do
      # Create both the master and the replica, with a simple small schema
      [@master_connection_config, @replica_connection_config].each do | db_config |
        ActiveRecord::Base.establish_connection(db_config)
        ActiveRecord::Schema.define(:version => 1) do
          create_table :things do |t|
            t.string :description, :null => true
            t.timestamps :null => false
          end
        end
      end
    end
  end

  after :all do
    # Ensure database files get killed afterwards
    [@master_connection_config, @replica_connection_config].map do | connection_config |
      File.unlink(connection_config[:database]) rescue nil
    end
  end

  before :each do
    allow(AutoReplica).to receive(:connection_set_up?).and_return(false)
    [@replica_connection_config, @master_connection_config].each do | config |
      AutoReplica.clear_current_read_pool
      ActiveRecord::Base.establish_connection(config)
      ActiveRecord::Base.connection.execute 'DELETE FROM things' # sqlite has no TRUNCATE
    end
  end

  class TestThing < ActiveRecord::Base
    self.table_name = 'things'
  end

  context 'using_read_replica_at' do
    it 'has no reentrancy problems' do
      id = described_class.using_read_replica_at(@replica_connection_config) do
        described_class.using_read_replica_at(@replica_connection_config) do
          described_class.using_read_replica_at(@replica_connection_config) do
            thing = TestThing.create! description: 'A nice Thing in the master database'
            expect {
              TestThing.find(thing.id)
            }.to raise_error(ActiveRecord::RecordNotFound)

            thing.id # return to the outside of the block
          end
        end
      end
      found_on_master = TestThing.find(id)
      expect(found_on_master.description).to eq('A nice Thing in the master database')
    end

    it 'executes the SELECT query against the replica database and returns the result of the block' do
      id = described_class.using_read_replica_at(@replica_connection_config) do
        thing = TestThing.create! description: 'A nice Thing in the master database'
        expect {
          TestThing.find(thing.id)
        }.to raise_error(ActiveRecord::RecordNotFound)
        thing.id
      end
      found_on_master = TestThing.find(id)
      expect(found_on_master.description).to eq('A nice Thing in the master database')

      ActiveRecord::Base.establish_connection(@replica_connection_config)
      thing_on_slave = TestThing.new(found_on_master.attributes)
      thing_on_slave.id = found_on_master.id # gets ignored in attributes
      thing_on_slave.description = 'A nice Thing that is in the slave database'
      thing_on_slave.save!

      ActiveRecord::Base.establish_connection(@master_connection_config)
      described_class.using_read_replica_at(@replica_connection_config) do
        thing_from_replica = TestThing.find(id)
        expect(thing_from_replica.description).to eq('A nice Thing that is in the slave database')
      end
    end

    it 'executes the SELECT query against the replica database with replica connection specification given as a URL' do
      id = described_class.using_read_replica_at(@replica_connection_config_url) do
        thing = TestThing.create! description: 'A nice Thing in the master database'
        expect {
          TestThing.find(thing.id)
        }.to raise_error(ActiveRecord::RecordNotFound)
        thing.id
      end
      found_on_master = TestThing.find(id)
      expect(found_on_master.description).to eq('A nice Thing in the master database')
    end

    it 'does not contaminate other threads with the replica connection' do
      ActiveRecord::Base.establish_connection(@master_connection_config)
      TestThing.create! description: 'In master'

      ActiveRecord::Base.establish_connection(@replica_connection_config)
      TestThing.create! description: 'In replica'

      ActiveRecord::Base.establish_connection(@master_connection_config)
      expect(TestThing.first.description).to eq('In master')

      ActiveRecord::Base.establish_connection(@replica_connection_config)
      expect(TestThing.first.description).to eq('In replica')

      ActiveRecord::Base.establish_connection(@master_connection_config)

      Thread.abort_on_exception = true
      failures = 0
      successes = 0
      lock = Mutex.new

      n_threads = 4
      n_iterations = 68
      readers_from_slave = (1..4).map do |n|
        Thread.new do
          n_iterations.times do
            sleep(rand / 3.0)
            described_class.using_read_replica_at(**@replica_connection_config) do
              description = TestThing.first.description
              lock.synchronize do
                if description == 'In replica'
                  successes += 1
                else
                  failures += 1
                end
              end
            end
          end
        end
      end

      readers_from_master = (1..n_threads).map do |n|
        Thread.new do
          n_iterations.times do
            sleep(rand / 3.0)
            description = TestThing.first.description
            lock.synchronize do
              if description == 'In master'
                successes += 1
              else
                failures += 1
              end
            end
          end
        end
      end

      readers_from_slave.map(&:join)
      readers_from_master.map(&:join)

      # All the fetches should be correct
      expect(successes).not_to be_zero

      # There should be no fetches from master in the replica block, and no fetches
      # from replica without the replica block
      expect(failures).to be_zero
    end
  end

  describe AutoReplica::ConnectionHandler do
    it 'proxies all methods' do
      original_handler = double('ActiveRecord_ConnectionHandler')
      expect(original_handler).to receive(:do_that_thing) { :yes }
      pool_double = double('ConnectionPool')
      subject = AutoReplica::ConnectionHandler.new(original_handler)
      expect(subject.do_that_thing).to eq(:yes)
    end

    it 'enhances connection_for and returns an instance of the Adapter if the thread-local :autoreplica is set' do
      Thread.current[:autoreplica] = true
      original_handler = double('ActiveRecord_ConnectionHandler')
      adapter_double = double('ActiveRecord_Adapter')
      connection_double = double('Connection')
      pool_double = double('ConnectionPool')
      expect(original_handler).to receive(:retrieve_connection).with(TestThing) { adapter_double }
      expect(pool_double).to receive(:connection) { connection_double }

      subject = AutoReplica::ConnectionHandler.new(original_handler)
      AutoReplica.current_read_pool = pool_double
      connection = subject.retrieve_connection(TestThing)
      expect(connection).to be_kind_of(AutoReplica::Adapter)
      AutoReplica.clear_current_read_pool
    end

    it 'returns the original connection without the wrapper if the thread-local :autoreplica is not set' do
      original_handler = double('ActiveRecord_ConnectionHandler')
      pool_double = double('Read replica pool')
      expect(original_handler).to receive(:retrieve_connection).and_return(:original_connection)
      subject = AutoReplica::ConnectionHandler.new(original_handler)
      AutoReplica.clear_current_read_pool
      connection = subject.retrieve_connection(TestThing)
      expect(connection).to eq(:original_connection)
    end

    it 'releases the the read pool connection when finishing' do
      original_handler = double('ActiveRecord_ConnectionHandler')
      pool_double = double('ConnectionPool')
      subject = AutoReplica::ConnectionHandler.new(original_handler)
      AutoReplica.current_read_pool = pool_double
      expect(pool_double).to receive(:release_connection)
      subject.finish_read_context
    end

    it 'performs clear_all_connections! both on the contained handler and on the read pool' do
      original_handler = double('ActiveRecord_ConnectionHandler')
      pool_double = double('ConnectionPool')

      expect(original_handler).to receive(:clear_all_connections!)
      expect(pool_double).to receive(:disconnect!)

      subject = AutoReplica::ConnectionHandler.new(original_handler)
      AutoReplica.current_read_pool = pool_double
      subject.clear_all_connections!
    end
  end

  describe AutoReplica::Adapter do
    it 'mirrors select_ prefixed database statement methods in ActiveRecord::ConnectionAdapters::DatabaseStatements' do
      master = double()
      expect(master).not_to receive(:respond_to?)
      subject = AutoReplica::Adapter.new(master, double())

      select_methods = ActiveRecord::ConnectionAdapters::DatabaseStatements.instance_methods.grep(/^select_/)
      expect(select_methods.length).to be > 1

      select_methods.each do | select_method_in_database_statements |
        expect(subject).to respond_to(select_method_in_database_statements)
      end
    end

    it 'redirects calls to all select_ methods to the read connection and others to the master connection' do
      master_adapter = double('Connection to the master DB')
      replica_adapter = double('Connection to the replica DB')
      subject = AutoReplica::Adapter.new(master_adapter, replica_adapter)

      expect(master_adapter).to receive(:some_arbitrary_method) { :from_master }
      expect(replica_adapter).to receive(:select_values).with(:a, :b, :c) { :from_replica }
      expect(subject.some_arbitrary_method).to eq(:from_master)
      expect(subject.select_values(:a, :b, :c)).to eq(:from_replica)
    end
  end
end

