module Delayed
  module MessageSending
    def send_later(method, prio=0, *args)
      Delayed::Job.enqueue Delayed::PerformableMethod.new(self, method.to_sym, args), prio
    end

    module ClassMethods
      def handle_asynchronously(method, prio=0)
        without_name = "#{method}_without_send_later"
        define_method("#{method}_with_send_later") do |*args|
          send_later(without_name, prio, *args)
        end
        alias_method_chain method, :send_later
      end
    end
  end
end
