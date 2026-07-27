require "rails_helper"

RSpec.describe ClearFinishedJobsJob do
  it "clears finished jobs past the cutoff but keeps recent and unfinished ones" do
    old_done = SolidQueue::Job.create!(queue_name: "low", class_name: "X", active_job_id: SecureRandom.uuid,
                                       finished_at: 3.days.ago)
    recent_done = SolidQueue::Job.create!(queue_name: "low", class_name: "X", active_job_id: SecureRandom.uuid,
                                          finished_at: 1.hour.ago)
    active = SolidQueue::Job.create!(queue_name: "low", class_name: "X", active_job_id: SecureRandom.uuid,
                                     finished_at: nil)

    described_class.perform_now

    expect(SolidQueue::Job.exists?(old_done.id)).to be(false)
    expect(SolidQueue::Job.exists?(recent_done.id)).to be(true)
    expect(SolidQueue::Job.exists?(active.id)).to be(true)
  end
end
