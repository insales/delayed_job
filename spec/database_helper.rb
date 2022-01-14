# frozen_string_literal: true

require 'logger'

class TestApplication < Rails::Application; end

ActiveRecord::Base.logger = Logger.new('/tmp/dj.log')
ActiveRecord::Base.establish_connection(
  adapter: 'postgresql',
  host: '127.0.0.1',
  database: 'paperclip_test',
  encoding: 'utf8',
  username: 'postgres',
  port: 5432
)
ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table :delayed_jobs, :force => true do |table|
    table.integer  :priority, :default => 0
    table.integer  :attempts, :default => 0
    table.text     :handler
    table.string   :last_error
    table.datetime :run_at
    table.datetime :locked_at
    table.string   :locked_by
    table.datetime :failed_at
    table.timestamps null: false
  end

  create_table :stories, :force => true do |table|
    table.string :text
  end
end

# Purely useful for test cases...
class Story < ActiveRecord::Base
  def tell; text; end
  def whatever(n, _); tell*n; end

  handle_asynchronously :whatever
end
