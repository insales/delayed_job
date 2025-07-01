# frozen_string_literal: true

require 'active_record'

class ApplicationRecord < ActiveRecord::Base
end

# NB: хак сработает только если это грузится до delayed/job, поэтому важно не реквайрить его руками из других мест
module Delayed
  JobSuperclass = ::ApplicationRecord
end

require 'delayed_job'
