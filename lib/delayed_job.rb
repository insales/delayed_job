require 'active_record'
require 'rails'

require 'delayed/message_sending'
require 'delayed/performable_method'
require 'delayed/lifecycle'
require 'delayed/plugin'
require 'delayed/plugins/clear_locks'
require 'delayed/job'
require 'delayed/worker'

require 'delayed/railtie' if defined?(Rails::Railtie)

Object.send(:include, Delayed::MessageSending)
Module.send(:include, Delayed::MessageSending::ClassMethods)
