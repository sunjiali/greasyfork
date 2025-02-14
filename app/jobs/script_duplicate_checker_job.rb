require 'zlib'

class ScriptDuplicateCheckerJob < ApplicationJob
  DESIRED_RUN_COUNT = 1

  queue_as :low
  self.max_concurrency = 2

  def perform(script_id)
    now = Time.current

    begin
      script = Script.find(script_id)
    rescue ActiveRecord::RecordNotFound
      return
    end

    other_scripts = Script.where.not(id: script_id)

    last_run = ScriptSimilarity.where(script_id:).maximum(:checked_at)
    if last_run && script.code_updated_at < last_run
      # Eliminate the ones we are up to date on
      up_to_date_script_ids = ScriptSimilarity.where(script_id:).joins(:other_script).where(['code_updated_at < ?', last_run]).pluck(:other_script_id)
      other_scripts = other_scripts.where.not(id: up_to_date_script_ids)
    end

    [true, false].each do |tersed|
      results = CodeSimilarityScorer.get_similarities(script, other_scripts, tersed:)

      next if results.none?

      ScriptSimilarity.where(script_id:, tersed:).delete_all
      bulk_data = results.sort_by(&:last).last(100).map { |other_script_id, similarity| { script_id:, other_script_id:, similarity: similarity.round(3), checked_at: now, tersed: } }
      ScriptSimilarity.upsert_all(bulk_data)
    end

    ScriptPreviouslyDeletedChecker.perform_later(script_id) if last_run.nil?
  end

  def self.currently_queued_script_ids
    return [] unless Rails.env.production?

    [
      currently_enqueued.map { |job| job.args.first['arguments'].first },
      currently_running.map { |p| p['args'].first['arguments'].first },
      currently_scheduled.map { |p| p['args'].first['arguments'].first },
    ].flatten
  end
end
