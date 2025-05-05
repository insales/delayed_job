module Delayed
  module MessageSending
    def send_later(method, prio=0, *args)
      performable_method = if self.is_a?(ShardedRecord) && self.respond_to?(:account_id)
                             Delayed::ShardedPerformableMethod.new(account_id, self, method.to_sym, args)
                           else
                             Delayed::PerformableMethod.new(self, method.to_sym, args)
                           end
      Delayed::Job.enqueue performable_method, prio
    end

    module ClassMethods
      def handle_asynchronously(method, prio=0)
        without_name = "#{method}_without_send_later"
        define_method("#{method}_with_send_later") do |*args|
          send_later(without_name, prio, *args)
        end

        alias_method without_name, method
        alias_method method, "#{method}_with_send_later"
      end
    end
  end
end
