# activerecord_autoreplica

[![Build Status](https://travis-ci.org/WeTransfer/activerecord_autoreplica.svg)](https://travis-ci.org/WeTransfer/activerecord_autoreplica)

An automatic ActiveRecord connection multiplexer, and is a reimplementation of / greatly inspired by
the [makara gem](https://github.com/taskrabbit/makara)

Automatically redirects your `SELECT` queries to a different database connection. Can be mighty
useful when you have a read replica defined and you want to make use of it for reporting or separate
tasks.

Does not require you to change the format of your `database.yml` or whatnot. Does not support replica weighting,
randomization, middleware contexts and other things that I do not need - it is very imperative and can be read
and changed in one sitting.

The only dependency is ActiveRecord itself.

### Usage

There are two options.

The first is to pass a complete ActiveRecord connection specificaton hash, and
everything within the block is going to use the read slave connections when performing standard
ActiveRecord `SELECT` queries (not the hand-written ones).

    AutoReplica.using_read_replica_at(:adapter => 'mysql2', :datbase => 'read_replica', ...) do
      customer = Customer.find(3) # Will SELECT from the replica database at the connection spec passed to the block
      customer.register_complaint! # Will UPDATE to the master database connection
    end

Connection strings (URLs) are also supported, just like in ActiveRecord itself:

    AutoReplica.using_read_replica_at('sqlite3:/replica_db_145.sqlite3') do
      ...
    end

Note that this will create and disconnect a ConnectionPool each time the block is called.

The other option is to create the ConnectionPool yourself, and pass it to `using_read_replica_pool`:

    AutoReplica.using_read_replica_pool(my_connection_pool) do
      ...
    end

This will release connections to the pool at the end of the block, but not close them.

To use in Rails controller context (for all actions of this controller):

    class SlowDataReportsController < ApplicationController
      around_filter ->{
        AutoReplica.using_read_replica_at(...) { yield }
      }
      ...
    end

To use in Rack middleware context:

    # Make sure to mount this downstream from ActiveRecord::ConnectionManagement in Rails
    def call(env)
      AutoReplica.using_read_replica_at(...) { @app.call(env) }
    end

Currently there are no runtime switches - once you are _in_ the block the `SELECT` queries composed via Arel will
all go to the read replica, no exception. If you do not want that - just exit the block.

The library does not make any assumptions about whether your data is up to date on the read slave versus master, so
act accordingly.

The `using_read_replica_at` block will allocate a `ConnectionPool` like the standard `ActiveRecord` connection
manager does, and the pool is going to be closed and torn down at the end of the block. Since it only uses the basic
ActiveRecord facilities (including mutexes) it should be threadsafe (but _not_ thread-local since the connection
handler in ActiveRecord isn't).

### Running the specs

You will only need sqlite3 and it's gem. Separate database files are going to be created for the master and replica and those
files are going to be erased on test completion.

There are Gemfiles for testing against various versions of ActiveRecord. To run those, use:

    $ BUNDLE_GEMFILE=gemfiles/Gemfile.rails-5.0.x bundle exec rake
    $ BUNDLE_GEMFILE=gemfiles/Gemfile.rails-4.1.x bundle exec rake
    $ BUNDLE_GEMFILE=gemfiles/Gemfile.rails-3.2.x bundle exec rake

The library contains a couple of switches that allow it to function in all these Rails versions.
Rails 3.x support is likely to be dropped in the next major version.

### Versioning

The gem version is specified in the Rakefile.

### Contributing to activerecord_autoreplica

* Check out the latest master to make sure the feature hasn't been implemented or the bug hasn't been fixed yet.
* Check out the issue tracker to make sure someone already hasn't requested it and/or contributed it.
* Fork the project.
* Start a feature/bugfix branch.
* Commit and push until you are happy with your contribution.
* Make sure to add tests for it. This is important so I don't break it in a future version unintentionally.
* Please try not to mess with the Rakefile, version, or history. If you want to have your own version, or is otherwise necessary, that is fine, but please isolate to its own commit so I can cherry-pick around it.

### Copyright

Copyright (c) 2014 WeTransfer. See LICENSE.txt for
further details.

