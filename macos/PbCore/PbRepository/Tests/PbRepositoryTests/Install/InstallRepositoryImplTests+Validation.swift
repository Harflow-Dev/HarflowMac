import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

/// Validation's diagnostic order (destination → effective selection → contracts → barrier), the
/// captured `uv` staying fixed through the whole operation, and the concurrency guards on `install()`.
extension InstallRepositoryImplTests {

    // MARK: Validation diagnostic order and messages

    @Test func givenCtlMissingFromTheDestination_whenValidating_thenItFailsEvenIfACompatibleCtlIsOnTheEffectivePath() async {
        // given — `isExecutable` (the destination check) reports ctl missing there, while the
        // locator would otherwise happily resolve a *different*, perfectly valid ctl elsewhere; the
        // destination check must still win (diagnostic order: destination first).
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment(
            locatorIsExecutable: { $0 == "/opt/homebrew/bin/polybridge-ctl" || $0 == InstallRepositoryImplTests.setupPath }
        )
        let sut = makeSUT(
            toolEnvironment: toolEnvironment,
            isExecutable: { path in path == InstallRepositoryImplTests.gitPath || path == InstallRepositoryImplTests.setupPath }
        )

        // when
        await sut.install()

        // then
        guard case .failed(.validate, let message) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }
        #expect(message.contains("polybridge-ctl isn't in it"))
    }

    @Test func givenSettingsOverrideShadowsTheNewInstall_whenValidating_thenTheOverrideMessageIsShown() async {
        // given — the locator resolves to the Settings override folder instead of the destination.
        let overrideDirectory = "/Users/fixture/override"
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment(
            overrideDirectory: overrideDirectory,
            locatorIsExecutable: { $0 == overrideDirectory + "/polybridge-ctl" || $0 == InstallRepositoryImplTests.setupPath }
        )
        let settings = InstallRepositoryImplTests.makeSettings(toolDirectory: overrideDirectory)
        let sut = makeSUT(toolEnvironment: toolEnvironment, settings: settings)

        // when
        await sut.install()

        // then
        guard case .failed(.validate, let message) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }
        #expect(message.contains("Settings → General"))
        #expect(message.contains(overrideDirectory))
    }

    @Test func givenANonOverrideShadow_whenValidating_thenAGenericAnotherPolybridgeMessageIsShown() async {
        // given — nothing is set in Settings, but the locator still resolves elsewhere (e.g. a
        // Homebrew install) ahead of the destination.
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment(
            locatorIsExecutable: { $0 == "/opt/homebrew/bin/polybridge-ctl" || $0 == InstallRepositoryImplTests.setupPath }
        )
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        await sut.install()

        // then
        guard case .failed(.validate, let message) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }
        #expect(message.contains("Another polybridge"))
        #expect(!message.contains("Settings → General"))
    }

    @Test func givenAnOverrideIsSetButDoesNotShadowTheNewInstall_whenValidating_thenNoOverrideMessageIsShown() async {
        // given — Settings has an override, but the locator (using it) still resolves to exactly the
        // new install's own destination — i.e. the override *is* the destination.
        let overrideDirectory = InstallRepositoryImplTests.destination
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment(overrideDirectory: overrideDirectory)
        let settings = InstallRepositoryImplTests.makeSettings(toolDirectory: overrideDirectory)
        let sut = makeSUT(toolEnvironment: toolEnvironment, settings: settings)

        // when
        await sut.install()

        // then — validation proceeds past the shadow check entirely.
        #expect(sut.state == .installed)
    }

    @Test func givenAShadowInAFolderWhoseNameMerelyStartsWithTheOverride_whenValidating_thenNoOverrideMessageIsShown() async {
        // given — the effective ctl is in `/Users/fixture/override-old`, and the override is
        // `/Users/fixture/override`: a string prefix, but not the same folder.
        let shadowDirectory = "/Users/fixture/override-old"
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment(
            overrideDirectory: shadowDirectory,
            locatorIsExecutable: { $0 == shadowDirectory + "/polybridge-ctl" || $0 == InstallRepositoryImplTests.setupPath }
        )
        let settings = InstallRepositoryImplTests.makeSettings(toolDirectory: "/Users/fixture/override")
        let sut = makeSUT(toolEnvironment: toolEnvironment, settings: settings)

        // when
        await sut.install()

        // then
        guard case .failed(.validate, let message) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }
        #expect(message.contains("Another polybridge"))
        #expect(!message.contains("Settings → General"))
    }

    @Test func givenCtlListReturnsAnUnsupportedVersion_whenValidating_thenTheContractFailureIsShown() async {
        // given — v6 is outside `ctlContractVersions` ({1, 2, 3, 4, 5}); v2 added
        // `resume_command` (Monitor piece 3/3) and is accepted, covered below.
        let runner = InstallRepositoryImplTests.makeRunner(
            ctlListJSON: #"{"v":6,"tasks":[]}"#
        )
        let sut = makeSUT(runner: runner)

        // when
        await sut.install()

        // then
        guard case .failed(.validate, let message) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }
        #expect(message.contains("contract version"))
    }

    @Test func givenCtlListReturnsSupportedVersion_whenValidating_thenAllAreAccepted() async {
        for version in [1, 2, 3, 4, 5] {
            // given
            let runner = InstallRepositoryImplTests.makeRunner(
                ctlListJSON: #"{"v":\#(version),"tasks":[]}"#
            )
            let sut = makeSUT(runner: runner)

            // when
            await sut.install()

            // then
            #expect(sut.state == .installed, "v\(version) should validate: \(sut.state)")
        }
    }

    @Test func givenSetupStatusReturnsAnUnsupportedVersion_whenValidating_thenTheContractFailureIsShown() async {
        // given — `setupContractVersion` stayed at 1; v2 (ctl's new version) is not a setup version
        // it understands.
        let runner = InstallRepositoryImplTests.makeRunner(
            setupStatusJSON: #"{"v":2,"clients":[]}"#
        )
        let sut = makeSUT(runner: runner)

        // when
        await sut.install()

        // then
        guard case .failed(.validate, let message) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }
        #expect(message.contains("contract version"))
    }

    @Test func givenSetupStatusIsUnreadable_whenValidating_thenTheContractFailureIsShown() async {
        // given
        let runner = InstallRepositoryImplTests.makeRunner { call in
            call.executable == InstallRepositoryImplTests.setupPath
                ? .success(ProcessOutput(exitCode: 1, stdout: Data(), stderr: "boom", timedOut: false))
                : nil
        }
        let sut = makeSUT(runner: runner)

        // when
        await sut.install()

        // then
        guard case .failed(.validate, let message) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }
        #expect(message.contains("boom"))
    }

    @Test func givenTheBarrierRefreshFails_whenValidating_thenStateBecomesFailedValidate() async {
        // given
        let taskList = InstallRepositoryImplTests.makeTaskList(refreshAndWait: .failure(.timedOut(tool: "polybridge-ctl", seconds: 30)))
        let sut = makeSUT(taskList: taskList)

        // when
        await sut.install()

        // then
        guard case .failed(.validate, let message) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }
        #expect(message.contains("did not answer"))
    }

    @Test func givenTheBarrierRefreshSucceeds_whenValidating_thenStateBecomesInstalled() async {
        // given
        let sut = makeSUT()

        // when
        await sut.install()

        // then
        #expect(sut.state == .installed)
    }

    // MARK: The captured `uv` is used through validation

    @Test func givenALaterDiscoveryPublishesADifferentUv_whenValidating_thenTheCapturedUvIsStillUsed() async {
        // given — the published discovery changes to another uv right after the operation captured
        // its own; validation must keep checking the captured destination.
        let capturedUv = InstallRepositoryImplTests.uv(binDirectory: InstallRepositoryImplTests.destination)
        let laterUv = InstallRepositoryImplTests.uv(binDirectory: "/somewhere/else")
        let published = LockedBox<UvResolution?>(capturedUv)
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).home.willReturn(InstallRepositoryImplTests.home)
        given(toolEnvironment).environment(toolDirectory: .any).willReturn(InstallRepositoryImplTests.pathEnvironment)
        given(toolEnvironment).discoverEnvironment().willProduce { DiscoveryResult(loginPath: nil, uv: published.value) }
        given(toolEnvironment).discovery.willProduce { DiscoveryResult(loginPath: nil, uv: published.value) }
        given(toolEnvironment).locator.willReturn(InstallRepositoryImplTests.makeLocator())
        let runner = InstallRepositoryImplTests.makeRunner { call in
            // Mid-install, another discovery publishes a different uv.
            if call.executable == InstallRepositoryImplTests.uvExecutable { published.mutate { $0 = laterUv } }
            return nil
        }
        let sut = makeSUT(toolEnvironment: toolEnvironment, runner: runner)

        // when
        await sut.install()

        // then — both contracts ran against the captured destination's binaries, never the later one.
        #expect(sut.state == .installed)
        let executables = runner.calls.map(\.executable)
        #expect(executables.contains(InstallRepositoryImplTests.ctlPath))
        #expect(executables.contains(InstallRepositoryImplTests.setupPath))
        #expect(!executables.contains { $0.hasPrefix("/somewhere/else") })
    }

    @Test func givenTheEffectiveSetupCannotBeLocated_whenValidating_thenValidationFails() async {
        // given — the destination holds both tools, but the app's own search path finds no setup.
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment(
            locatorIsExecutable: { $0 == InstallRepositoryImplTests.ctlPath }
        )
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        await sut.install()

        // then
        guard case .failed(.validate, let message) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }
        #expect(message.contains("polybridge-setup"))
    }

    @Test func givenGitExistsOnlyInTheUvDestination_whenInstalling_thenTheGitCheckUsesUvsPath() async {
        // given — the only git is in the uv bin folder, which is on the PATH uv runs with but not on
        // the plain login PATH; checking any other PATH would report needsGit.
        let destinationGit = InstallRepositoryImplTests.destination + "/git"
        let sut = makeSUT(isExecutable: { path in
            path == destinationGit || path == InstallRepositoryImplTests.ctlPath || path == InstallRepositoryImplTests.setupPath
        })

        // when
        await sut.install()

        // then
        #expect(sut.state == .installed)
    }

    @Test func givenUnresolvedAtTheUvStage_whenUvHasSinceBeenInstalled_thenCheckAgainDiscoversItAndPasses() async {
        // given — the uv bootstrap timed out before any uv was captured; by the check, discovery
        // finds uv and a working install.
        let discoveredUv = LockedBox<UvResolution?>(nil)
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).home.willReturn(InstallRepositoryImplTests.home)
        given(toolEnvironment).environment(toolDirectory: .any).willReturn(InstallRepositoryImplTests.pathEnvironment)
        given(toolEnvironment).discoverEnvironment().willProduce { DiscoveryResult(loginPath: nil, uv: discoveredUv.value) }
        given(toolEnvironment).discovery.willProduce { DiscoveryResult(loginPath: nil, uv: discoveredUv.value) }
        given(toolEnvironment).locator.willReturn(InstallRepositoryImplTests.makeLocator())
        let runner = InstallRepositoryImplTests.makeRunner { call in
            call.executable == InstallCommands.shExecutable
                ? .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
                : nil
        }
        let sut = makeSUT(toolEnvironment: toolEnvironment, runner: runner)
        await sut.install()
        #expect(sut.state == .needsUv)
        await sut.installUvThenPolybridge()
        #expect(sut.state == .unresolved(stage: .uv))
        discoveredUv.mutate { $0 = InstallRepositoryImplTests.uv() }

        // when
        await sut.checkAgain()

        // then
        #expect(sut.state == .installed)
    }

    @Test func givenUnresolved_whenAskingForTheDestination_thenTheCapturedOneIsNamed() async {
        // given — the operation captured one destination; discovery has since published another.
        let laterUv = InstallRepositoryImplTests.uv(binDirectory: "/somewhere/else")
        let published = LockedBox<UvResolution?>(InstallRepositoryImplTests.uv())
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).home.willReturn(InstallRepositoryImplTests.home)
        given(toolEnvironment).environment(toolDirectory: .any).willReturn(InstallRepositoryImplTests.pathEnvironment)
        given(toolEnvironment).discoverEnvironment().willProduce { DiscoveryResult(loginPath: nil, uv: published.value) }
        given(toolEnvironment).discovery.willProduce { DiscoveryResult(loginPath: nil, uv: published.value) }
        given(toolEnvironment).locator.willReturn(InstallRepositoryImplTests.makeLocator())
        let runner = InstallRepositoryImplTests.makeRunner { call in
            guard call.executable == InstallRepositoryImplTests.uvExecutable else { return nil }
            published.mutate { $0 = laterUv }
            return .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
        }
        let sut = makeSUT(toolEnvironment: toolEnvironment, runner: runner)
        await sut.install()
        #expect(sut.state == .unresolved(stage: .polybridge))

        // when
        let destination = sut.destination()

        // then — Install anyway would reinstall into the captured destination, so that is the one named.
        #expect(destination == InstallRepositoryImplTests.destination)
    }

    @Test func givenUvIsAlreadyKnown_whenInstalling_thenTheShownDestinationIsUsedWithoutRediscovering() async {
        // given — the published discovery (what the confirmation dialog named) already has uv.
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment()
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        await sut.install()

        // then
        #expect(sut.state == .installed)
        verify(toolEnvironment).discoverEnvironment().called(0)
    }

    @Test func givenTheNewUvFolderLeadsWithABrokenGit_whenUvIsBootstrapped_thenStateBecomesNeedsGit() async {
        // given — git passes before uv exists; the bootstrapped uv's folder then puts a broken git
        // first on the PATH uv would run with.
        let discoveredUv = LockedBox<UvResolution?>(nil)
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).home.willReturn(InstallRepositoryImplTests.home)
        given(toolEnvironment).environment(toolDirectory: .any).willReturn(InstallRepositoryImplTests.pathEnvironment)
        given(toolEnvironment).discoverEnvironment().willProduce { DiscoveryResult(loginPath: nil, uv: discoveredUv.value) }
        given(toolEnvironment).discovery.willProduce { DiscoveryResult(loginPath: nil, uv: discoveredUv.value) }
        given(toolEnvironment).locator.willReturn(InstallRepositoryImplTests.makeLocator())
        let brokenGit = InstallRepositoryImplTests.destination + "/git"
        let runner = InstallRepositoryImplTests.makeRunner { call in
            if call.executable == InstallCommands.shExecutable { discoveredUv.mutate { $0 = InstallRepositoryImplTests.uv() } }
            return call.executable == brokenGit ? .success(ProcessOutput(exitCode: 1, stdout: Data(), stderr: "", timedOut: false)) : nil
        }
        let sut = makeSUT(toolEnvironment: toolEnvironment, runner: runner, isExecutable: { path in
            path == InstallRepositoryImplTests.gitPath || path == brokenGit
                || path == InstallRepositoryImplTests.ctlPath || path == InstallRepositoryImplTests.setupPath
        })
        await sut.install()
        #expect(sut.state == .needsUv)

        // when
        await sut.installUvThenPolybridge()

        // then — never reached the polybridge install.
        #expect(sut.state == .needsGit)
        #expect(!runner.calls.contains { $0.executable == InstallRepositoryImplTests.uvExecutable })
    }

    // MARK: Concurrency guards

    @Test func givenAnOperationAlreadyRunning_whenInstallIsCalledAgain_thenTheSecondCallIsANoOp() async {
        // given
        let gate = AsyncGate()
        let polybridgeCalls = LockedBox(0)
        let runner = InstallRepositoryImplTests.makeRunner { call in
            guard call.executable == InstallRepositoryImplTests.uvExecutable else { return nil }
            polybridgeCalls.mutate { $0 += 1 }
            gate.waitSync()
            return .success(stdout(""))
        }
        let sut = makeSUT(runner: runner)

        // when
        let firstInstall = Task { await sut.install() }
        await waitUntil { sut.state == .running(.polybridge) }
        await sut.install() // concurrent second call
        gate.open()
        await firstInstall.value

        // then — only one polybridge install ever ran.
        #expect(polybridgeCalls.value == 1)
        #expect(sut.state == .installed)
    }
}
