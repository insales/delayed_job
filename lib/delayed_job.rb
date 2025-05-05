require 'active_record'
require 'rails'

require 'delayed/message_sending'
require 'delayed/performable_method'
require 'delayed/sharded_performable_method'
require 'delayed/job'
require 'delayed/worker'

require 'delayed/railtie' if defined?(Rails::Railtie)

Object.send(:include, Delayed::MessageSending)
Module.send(:include, Delayed::MessageSending::ClassMethods)
