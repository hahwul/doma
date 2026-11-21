require "./spec_helper"

describe Doma::GitDetector do
  it "omits relative local remotes from portable snapshots" do
    dir = File.tempname("doma-portable-remote")
    git_dir = File.join(dir, ".git")
    FileUtils.mkdir_p(git_dir)
    begin
      config = File.join(git_dir, "config")
      ["repo.git", "repos/repo.git", "./repo.git", "../repo.git", "./repos/name:repo.git"].each do |url|
        File.write(config, %([remote "origin"]\n\turl = #{url}\n))
        Doma::GitDetector.origin_url(dir).should be_nil
      end
      ["/srv/git/repo.git", "file:///srv/git/repo.git", "host:repo.git"].each do |url|
        File.write(config, %([remote "origin"]\n\turl = #{url}\n))
        Doma::GitDetector.origin_url(dir).should eq(url)
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
