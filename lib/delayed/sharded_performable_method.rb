# frozen_string_literal: true

module Delayed
  class ShardedPerformableMethod < PerformableMethod
    attr_accessor :account_id

    def initialize(account_id, object, method, args)
      @account_id = account_id
      super(object, method, args)
    end

    def perform
      shard = Account.unscoped.fetch_shard_by_id(account_id)
      raise 'Shard not found' unless shard

      ShardedRecord.connected_to_shard(shard) { super }
    end
  end
end
