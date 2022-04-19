require 'database_helper'

describe "A story" do

  before(:all) do
    @story = Story.create :text => "Once upon a time..."
  end

  it "should be shared" do
    expect(@story.tell).to eq 'Once upon a time...'
  end

  it "should not return its result if it storytelling is delayed" do
    expect(@story.send_later(:tell)).not_to eq 'Once upon a time...'
  end

end
