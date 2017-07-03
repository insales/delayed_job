module Delayed
  class PerformableMethod < Struct.new(:object, :method, :args)
    CLASS_STRING_FORMAT = /^CLASS\:([A-Z][\w\:]+)$/
    AR_STRING_FORMAT    = /^AR\:([A-Z][\w\:]+)\:(\d+)$/

    def initialize(object, method, args)
      self.object = dump(object)
      self.args   = args.map { |a| dump(a) }
      self.method = method.to_sym

      raise NoMethodError, "undefined method `#{method}' for #{object.inspect}" unless object.respond_to?(method, true)
    end

    def display_name
      case self.object
      when CLASS_STRING_FORMAT then "#{$1}.#{method}"
      when AR_STRING_FORMAT    then "#{$1}##{method}"
      else "Unknown##{method}"
      end
    end

    def perform
      obj = load(object)
      use_obj_time_zone(obj)
      obj.send(method, *args.map{|a| load(a)})
    rescue ActiveRecord::RecordNotFound
      # We cannot do anything about objects which were deleted in the meantime
      true
    ensure
      Time.zone = Rails::configuration.time_zone
    end

    private

    def load(arg)
      case arg
      when CLASS_STRING_FORMAT then $1.constantize
      when AR_STRING_FORMAT    then $1.constantize.find($2)
      else arg
      end
    end

    def dump(arg)
      case arg
      when Class              then class_to_string(arg)
      when ActiveRecord::Base then ar_to_string(arg)
      else arg
      end
    end

    def ar_to_string(obj)
      "AR:#{obj.class}:#{obj.id}"
    end

    def class_to_string(obj)
      "CLASS:#{obj.name}"
    end

    def use_obj_time_zone(obj)
      account = if obj.is_a? Account
                  obj
                elsif obj.respond_to?(:account) && obj.account && obj.account.is_a?(Account)
                  obj.account
                else
                  nil
                end
      if account
        Time.zone = account.get_time_zone
      end
    end
  end
end
