# typed: true
# frozen_string_literal: true

require "spec_helper"
require "dependabot/source"
require "dependabot/nuget/file_parser"
require "dependabot/nuget/file_updater"
require "dependabot/nuget/version"
require_relative "github_helpers"
require_relative "nuget_search_stubs"
require "json"
require_common_spec "file_updaters/shared_examples_for_file_updaters"

RSpec.describe Dependabot::Nuget::FileUpdater do
  RSpec.configure do |config|
    config.include(NuGetSearchStubs)
  end

  let(:stub_native_tools) { true } # set to `false` to allow invoking the native tools during tests
  let(:report_stub_debug_information) { false } # set to `true` to write native tool stubbing information to the screen

  let(:source) do
    Dependabot::Source.new(
      provider: "github",
      repo: "gocardless/bump",
      directory: "/"
    )
  end
  let(:dependencies) { [dependency] }
  let(:project_name) { "file_updater_dirsproj" }
  let(:directory) { "/" }
  # project_dependency files comes back with directory files first, we need the closest project at the top
  let(:dependency_files) { nuget_project_dependency_files(project_name, directory: directory).reverse }
  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: dependency_version,
      previous_version: dependency_previous_version,
      requirements: requirements,
      previous_requirements: previous_requirements,
      package_manager: "nuget"
    )
  end
  let(:dependency_name) { "Microsoft.Extensions.DependencyModel" }
  let(:dependency_version) { "1.1.1" }
  let(:dependency_previous_version) { "1.0.0" }
  let(:requirements) do
    [{ file: "dirs.proj", requirement: "1.1.1", groups: [], source: nil }]
  end
  let(:previous_requirements) do
    [{ file: "dirs.proj", requirement: "1.0.0", groups: [], source: nil }]
  end
  let(:repo_contents_path) { nuget_build_tmp_repo(project_name) }

  before do
    stub_search_results_with_versions_v3("microsoft.extensions.dependencymodel", ["1.0.0", "1.1.1"])
    stub_request(:get, "https://api.nuget.org/v3-flatcontainer/" \
                       "microsoft.extensions.dependencymodel/1.0.0/" \
                       "microsoft.extensions.dependencymodel.nuspec")
      .to_return(status: 200, body: fixture("nuspecs", "Microsoft.Extensions.DependencyModel.1.0.0.nuspec"))
  end

  it_behaves_like "a dependency file updater"

  def run_update_test(&_block)
    # caching is explicitly required for these tests
    ENV["DEPENDABOT_NUGET_CACHE_DISABLED"] = "false"

    # don't allow a previous test to pollute the file parser cache
    Dependabot::Nuget::FileParser.file_dependency_cache.clear

    # calling `#parse` is necessary to force `discover` which is stubbed below
    Dependabot::Nuget::FileParser.new(dependency_files: dependency_files,
                                      source: source,
                                      repo_contents_path: repo_contents_path).parse

    # create the file updater...
    updater = described_class.new(
      dependency_files: dependency_files,
      dependencies: dependencies,
      credentials: [{
        "type" => "git_source",
        "host" => "github.com"
      }],
      repo_contents_path: repo_contents_path
    )

    # ...and invoke the actual test
    yield updater
  ensure
    Dependabot::Nuget::NativeDiscoveryJsonReader.clear_discovery_file_path_from_cache(dependency_files)
    ENV["DEPENDABOT_NUGET_CACHE_DISABLED"] = "true"
  end

  def intercept_native_tools(discovery_content_hash:)
    return unless stub_native_tools

    # don't allow `FileParser#parse` to call into the native tool; just fake it
    allow(Dependabot::Nuget::NativeHelpers)
      .to receive(:run_nuget_discover_tool)
      .and_wrap_original do |_original_method, *args, &_block|
        discovery_json_path = args[0][:output_path]
        FileUtils.mkdir_p(File.dirname(discovery_json_path))
        if report_stub_debug_information
          puts "stubbing call to `run_nuget_discover_tool` with args #{args}; writing prefabricated discovery " \
               "response to discovery.json to #{discovery_json_path}"
        end
        discovery_json_content = discovery_content_hash.to_json
        File.write(discovery_json_path, discovery_json_content)
      end
  end

  describe "#updated_files_regex" do
    subject(:updated_files_regex) { described_class.updated_files_regex(allowlist_enabled) }

    let(:allowlist_enabled) { true }

    it "is not empty" do
      expect(updated_files_regex).not_to be_empty
    end

    context "when files match the regex patterns" do
      it "returns true for files that should be updated" do
        matching_files = [
          "project.csproj",
          "library.fsproj",
          "app.vbproj",
          "packages.config",
          "app.config",
          "web.config",
          "global.json",
          "dotnet-tools.json",
          "Directory.Build.props",
          "Directory.Build.targets",
          "Packages.props",
          "Proj1/Proj1/Proj1.csproj"
        ]

        matching_files.each do |file_name|
          expect(updated_files_regex).to(be_any { |regex| file_name.match?(regex) })
        end
      end

      it "returns false for files that should not be updated" do
        non_matching_files = [
          "README.md",
          ".github/workflow/main.yml",
          "some_random_file.rb",
          "requirements.txt",
          "package-lock.json",
          "package.json",
          "Gemfile",
          "Gemfile.lock",
          "NuGet.Config",
          "nuget.config",
          "Proj1/Proj1/NuGet.Config",
          "Proj1/Proj1/test/nuGet.config"
        ]

        non_matching_files.each do |file_name|
          expect(updated_files_regex).not_to(be_any { |regex| file_name.match?(regex) })
        end
      end
    end
  end

  describe "#updated_dependency_files" do
    before do
      intercept_native_tools(
        discovery_content_hash: {
          Path: "",
          IsSuccess: true,
          Projects: [
            {
              FilePath: "Proj1/Proj1/Proj1.csproj",
              Dependencies: [{
                Name: "Microsoft.Extensions.DependencyModel",
                Version: "1.0.0",
                Type: "PackageReference",
                EvaluationResult: nil,
                TargetFrameworks: ["net461"],
                IsDevDependency: false,
                IsDirect: true,
                IsTransitive: false,
                IsOverride: false,
                IsUpdate: false,
                InfoUrl: nil
              }],
              IsSuccess: true,
              Properties: [{
                Name: "TargetFramework",
                Value: "net461",
                SourceFilePath: "Proj1/Proj1/Proj1.csproj"
              }],
              TargetFrameworks: ["net461"],
              ReferencedProjectPaths: []
            }
          ],
          DirectoryPackagesProps: nil,
          GlobalJson: nil,
          DotNetToolsJson: nil
        }
      )
    end

    context "with a dirs.proj" do
      it "does not repeatedly update the same project" do
        run_update_test do |updater|
          expect(updater.updated_dependency_files.map(&:name)).to contain_exactly("Proj1/Proj1/Proj1.csproj")

          expect(updater.send(:testonly_update_tooling_calls)).to eq(
            {
              "/Proj1/Proj1/Proj1.csproj+Microsoft.Extensions.DependencyModel" => 1
            }
          )
        end
      end
    end
  end

  describe "#updated_dependency_files_with_wildcard" do
    let(:project_name) { "file_updater_dirsproj_wildcards" }
    let(:dependency_files) { nuget_project_dependency_files(project_name, directory: directory).reverse }
    let(:dependency_name) { "Microsoft.Extensions.DependencyModel" }
    let(:dependency_version) { "1.1.1" }
    let(:dependency_previous_version) { "1.0.0" }

    before do
      intercept_native_tools(
        discovery_content_hash: {
          Path: "",
          IsSuccess: true,
          Projects: [
            {
              FilePath: "Proj1/Proj1/Proj1.csproj",
              Dependencies: [{
                Name: "Microsoft.Extensions.DependencyModel",
                Version: "1.0.0",
                Type: "PackageReference",
                EvaluationResult: nil,
                TargetFrameworks: ["net461"],
                IsDevDependency: false,
                IsDirect: true,
                IsTransitive: false,
                IsOverride: false,
                IsUpdate: false,
                InfoUrl: nil
              }],
              IsSuccess: true,
              Properties: [{
                Name: "TargetFramework",
                Value: "net461",
                SourceFilePath: "Proj1/Proj1/Proj1.csproj"
              }],
              TargetFrameworks: ["net461"],
              ReferencedProjectPaths: []
            }, {
              FilePath: "Proj2/Proj2.csproj",
              Dependencies: [{
                Name: "Microsoft.Extensions.DependencyModel",
                Version: "1.0.0",
                Type: "PackageReference",
                EvaluationResult: nil,
                TargetFrameworks: ["net461"],
                IsDevDependency: false,
                IsDirect: true,
                IsTransitive: false,
                IsOverride: false,
                IsUpdate: false,
                InfoUrl: nil
              }],
              IsSuccess: true,
              Properties: [{
                Name: "TargetFramework",
                Value: "net461",
                SourceFilePath: "Proj2/Proj2.csproj"
              }],
              TargetFrameworks: ["net461"],
              ReferencedProjectPaths: []
            }
          ],
          DirectoryPackagesProps: nil,
          GlobalJson: nil,
          DotNetToolsJson: nil
        }
      )
    end

    it "updates the wildcard project" do
      run_update_test do |updater|
        expect(updater.updated_dependency_files.map(&:name)).to contain_exactly("Proj1/Proj1/Proj1.csproj",
                                                                                "Proj2/Proj2.csproj")

        expect(updater.send(:testonly_update_tooling_calls)).to eq(
          {
            "/Proj1/Proj1/Proj1.csproj+Microsoft.Extensions.DependencyModel" => 1,
            "/Proj2/Proj2.csproj+Microsoft.Extensions.DependencyModel" => 1
          }
        )
      end
    end
  end

  describe "#differs_in_more_than_blank_lines?" do
    subject(:result) { described_class.differs_in_more_than_blank_lines?(original_content, updated_content) }

    context "when the original content is `nil` and updated is empty" do
      let(:original_content) { nil }
      let(:updated_content) { "" }

      it { is_expected.to be(false) }
    end

    context "when the original content is `nil` and updated is non-empty" do
      let(:original_content) { nil }
      let(:updated_content) { "line1\nline2" }

      it { is_expected.to be(true) }
    end

    context "when there is a difference with no blank lines" do
      let(:original_content) do
        <<~TEXT
          original-line-1
          original-line-2
          original-line-3
        TEXT
      end
      let(:updated_content) do
        <<~TEXT
          original-line-1
          UPDATED-LINE-2
          original-line-3
        TEXT
      end

      it { is_expected.to be(true) }
    end

    context "when there is a difference with blank lines" do
      let(:original_content) do
        <<~TEXT
          original-line-1

          original-line-2
          original-line-3
        TEXT
      end
      let(:updated_content) do
        <<~TEXT
          original-line-1

          UPDATED-LINE-2
          original-line-3
        TEXT
      end

      it { is_expected.to be(true) }
    end

    context "when a blank line was added" do
      let(:original_content) do
        <<~TEXT
          original-line-1
          original-line-2
          original-line-3
        TEXT
      end
      let(:updated_content) do
        <<~TEXT
          original-line-1

          original-line-2
          original-line-3
        TEXT
      end

      it { is_expected.to be(false) }
    end

    context "when a blank line was removed, but no other changes" do
      let(:original_content) do
        <<~TEXT
          original-line-1

          original-line-2
          original-line-3
        TEXT
      end
      let(:updated_content) do
        <<~TEXT
          original-line-1
          original-line-2
          original-line-3
        TEXT
      end

      it { is_expected.to be(false) }
    end

    context "when a line was removed" do
      let(:original_content) do
        <<~TEXT
          original-line-1
          original-line-2
          original-line-3
        TEXT
      end
      let(:updated_content) do
        <<~TEXT
          original-line-1
          original-line-3
        TEXT
      end

      it { is_expected.to be(true) }
    end

    context "when a blank line was removed and another was changed" do
      let(:original_content) do
        <<~TEXT
          original-line-1

          original-line-2
          original-line-3
        TEXT
      end
      let(:updated_content) do
        <<~TEXT
          original-line-1
          UPDATED-LINE-2
          original-line-3
        TEXT
      end

      it { is_expected.to be(true) }
    end

    context "when a line was added and blank lines are present" do
      let(:original_content) do
        <<~TEXT
          original-line-1

          original-line-2
          original-line-3
        TEXT
      end
      let(:updated_content) do
        <<~TEXT
          original-line-1

          original-line-2
          SOME-NEW-LINE
          original-line-3
        TEXT
      end

      it { is_expected.to be(true) }
    end

    context "when the only difference is a trailing newline" do
      let(:original_content) { "line-1\nline-2\n" }
      let(:updated_content) { "line-1\nline-2" }

      it { is_expected.to be(false) }
    end
  end
end
