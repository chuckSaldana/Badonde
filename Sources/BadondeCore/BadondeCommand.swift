import Foundation
import SwiftCLI

extension TicketId {
	init?(branchName: String) {
		guard let ticketId = branchName.split(separator: "_").first else {
			return nil
		}
		self.init(rawValue: String(ticketId))
	}
}

extension IssueType {
	var isBug: Bool {
		return ["Bug", "Story Defect"].contains(name)
	}
}

class BadondeCommand: Command {
	enum Error: Swift.Error {
		case invalidBranchFormat
		case invalidPullRequestURL
	}

	let name = ""

	func numberOfCommits(fromBranch: String, toBranch: String) -> Int {
		guard let commitCount = try? capture(bash: "git log origin/\(toBranch)..origin/\(fromBranch) --oneline | wc -l").stdout else {
			return 0
		}
		return Int(commitCount) ?? 0
	}

	func baseBranch(forBranch branch: String) -> String {
		let developBranch = "develop"

		guard let localReleaseBranchesRaw = try? capture(bash: "git branch | grep \"release\"").stdout else {
			return developBranch
		}

		let releaseBranch = localReleaseBranchesRaw
			.replacingOccurrences(of: "\n  ", with: "\n")
			.split(separator: "\n")
			.filter { $0.hasPrefix("release/") }
			.compactMap { releaseBranch -> (version: Int, branch: String)? in
				let releaseBranch = String(releaseBranch)
				let versionNumberString = releaseBranch
					.replacingOccurrences(of: "release/", with: "")
					.replacingOccurrences(of: ".", with: "")
				guard let versionNumber = Int(versionNumberString) else {
					return nil
				}
				return (version: versionNumber, branch: releaseBranch)
			}
			.sorted { $0.version > $1.version }
			.first?
			.branch

		if let releaseBranch = releaseBranch {
			let numberOfCommitsToRelease = self.numberOfCommits(fromBranch: branch, toBranch: releaseBranch)
			let numberOfCommitsToDevelop = self.numberOfCommits(fromBranch: branch, toBranch: developBranch)

			if numberOfCommitsToRelease <= numberOfCommitsToDevelop {
				return releaseBranch
			}
		}

		return developBranch
	}

	func execute() throws {
//		let currentBranchName = "ISAV-12296"
		guard
			let currentBranchName = try? capture(bash: "git rev-parse --abbrev-ref HEAD").stdout,
			let ticketId = TicketId(branchName: currentBranchName)
		else {
			stdout <<< Error.invalidBranchFormat.localizedDescription
			return
		}

		let repoShorthand = "asosteam/asos-native-ios"
		let accessTokenStore = AccessTokenStore()
		let repoInfoFetcher: GitHubRepositoryInfoFetcher
		let ticketFetcher: TicketFetcher
		if let accessTokenConfig = accessTokenStore.config {
			repoInfoFetcher = GitHubRepositoryInfoFetcher(accessToken: accessTokenConfig.githubAccessToken)
			ticketFetcher = TicketFetcher(email: accessTokenConfig.jiraEmail, apiToken: accessTokenConfig.jiraApiToken)
		} else {
			// TODO: prompt for keys
			exit(EXIT_FAILURE)
		}

		repoInfoFetcher.fetchRepositoryInfo(withRepositoryShorthand: repoShorthand) { result in
			let repoInfo = result.value

			ticketFetcher.fetchTicket(with: ticketId) { result in
				switch result {
				case .success(let ticket):
					let pullRequestURLFactory = PullRequestURLFactory(repositoryShorthand: repoShorthand)
					// TODO: fetch possible dependency branch from related tickets
					pullRequestURLFactory.baseBranch = self.baseBranch(forBranch: currentBranchName)
					pullRequestURLFactory.targetBranch = currentBranchName
					pullRequestURLFactory.title = "[\(ticket.key)] \(ticket.fields.summary)"

					let repoLabels = repoInfo?.labels.map { $0.name } ?? []
					var pullRequestLabels: [String] = []

					// Append Bug label if ticket is a bug
					if ticket.fields.issueType.isBug {
						if let bugLabel = repoLabels.fuzzyMatch(word: "bug") {
							pullRequestLabels.append(bugLabel)
						}
					}

					// Append ticket's epic label if similar name is found in repo labels
					if let epic = ticket.fields.epicSummary {
						guard let epicLabel = repoLabels.fuzzyMatch(word: epic) else {
							return
						}
						pullRequestLabels.append(epicLabel)
					}

					pullRequestURLFactory.labels = pullRequestLabels.nilIfEmpty

					if
						let rawMilestone = ticket.fields.fixVersions.first?.name,
						!rawMilestone.isEmpty,
						let repoMilestones = repoInfo?.milestones.map({ $0.title })
					{
						if let milestone = repoMilestones.fuzzyMatch(word: rawMilestone) {
							pullRequestURLFactory.milestone = milestone
						}
					}

					guard let pullRequestURL = pullRequestURLFactory.url else {
						self.stdout <<< Error.invalidPullRequestURL.localizedDescription
						return
					}

					do {
						try run(bash: "open \"\(pullRequestURL)\"")
						exit(EXIT_SUCCESS)
					} catch {
						self.stdout <<< error.localizedDescription
					}
				case .failure(let error):
					self.stdout <<< error.localizedDescription
				}
			}
		}
	}
}
