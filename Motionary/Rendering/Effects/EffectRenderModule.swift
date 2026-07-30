import CoreImage
import Foundation

protocol EffectRenderModule: Sendable {
    var moduleID: EffectModuleID { get }

    func render(
        _ image: CIImage,
        effect: EffectInstance,
        context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult
}

extension EffectRenderModule {
    func scalar(
        _ parameterID: EffectParameterID,
        in effect: EffectInstance,
        at time: Double
    ) -> Double {
        guard case .scalar(let value)? = EffectRegistry.shared.resolvedValue(
            for: parameterID,
            in: effect,
            at: time
        ) else { return 0 }
        return value.isFinite ? value : 0
    }
}

final class EffectRenderRegistry: @unchecked Sendable {
    static let shared: EffectRenderRegistry = {
        do {
            return try EffectRenderRegistry(
                modules: EffectRegistry.shared.modules.map { $0.makeRenderer() }
            )
        } catch {
            preconditionFailure("Invalid effect render registry: \(error.localizedDescription)")
        }
    }()

    private let modulesByID: [EffectModuleID: any EffectRenderModule]

    init(modules: [any EffectRenderModule]) throws {
        var indexed: [EffectModuleID: any EffectRenderModule] = [:]
        for module in modules {
            guard indexed[module.moduleID] == nil else {
                throw EffectRegistryError.duplicateModuleID(module.moduleID)
            }
            guard EffectRegistry.shared.descriptor(for: module.moduleID) != nil else {
                throw MetalRenderingError.unavailableEffect(module.moduleID.rawValue)
            }
            indexed[module.moduleID] = module
        }
        modulesByID = indexed
    }

    func validate(_ stack: EffectStack) throws {
        for storedEffect in stack.effects where storedEffect.isEnabled {
            let effect = try EffectRegistry.shared.migrated(storedEffect)
            switch EffectRegistry.shared.availability(of: effect) {
            case .available:
                guard modulesByID[effect.moduleID] != nil else {
                    throw MetalRenderingError.unavailableEffect(effect.moduleID.rawValue)
                }
            case .unknownModule:
                throw MetalRenderingError.unavailableEffect(effect.moduleID.rawValue)
            case .unsupportedVersion(let requested, let supported):
                throw MetalRenderingError.unavailableEffect(
                    "\(effect.moduleID.rawValue) v\(requested) (renderer supports v\(supported))"
                )
            }
        }
    }

    func render(
        _ stack: EffectStack,
        to input: CIImage,
        context: EffectRenderContext,
        resources: MetalFrameResources,
        failurePolicy: RenderFailurePolicy
    ) throws -> CIImage {
        var current = input
        for storedEffect in stack.effects where storedEffect.isEnabled {
            let effect: EffectInstance
            do {
                effect = try EffectRegistry.shared.migrated(storedEffect)
            } catch {
                let diagnostic = EffectRenderDiagnostic(
                    severity: failurePolicy == .failOnUnavailableEffects ? .error : .warning,
                    moduleID: storedEffect.moduleID.rawValue,
                    effectID: storedEffect.id,
                    message: error.localizedDescription
                )
                EffectRenderDiagnostics.shared.report(diagnostic)
                if failurePolicy == .failOnUnavailableEffects { throw error }
                continue
            }
            let module: (any EffectRenderModule)?
            switch EffectRegistry.shared.availability(of: effect) {
            case .available:
                module = modulesByID[effect.moduleID]
            case .unknownModule, .unsupportedVersion:
                module = nil
            }

            guard let module else {
                let name = EffectRegistry.shared.descriptor(for: effect.moduleID)?.name
                    ?? "Unavailable Effect"
                let diagnostic = EffectRenderDiagnostic(
                    severity: failurePolicy == .failOnUnavailableEffects ? .error : .warning,
                    moduleID: effect.moduleID.rawValue,
                    effectID: effect.id,
                    message: "\(name) has no compatible renderer and was not rendered."
                )
                EffectRenderDiagnostics.shared.report(diagnostic)
                if failurePolicy == .failOnUnavailableEffects {
                    throw MetalRenderingError.unavailableEffect(name)
                }
                continue
            }

            let mix = EffectRegistry.shared.resolvedMix(in: effect, at: context.clipTime)
            guard mix > 0.000_1 else { continue }
            let result = try module.render(
                current,
                effect: effect,
                context: context,
                resources: resources
            )
            current = Self.mix(current, with: result.image, amount: mix)
        }
        return current
    }

    private static func mix(_ source: CIImage, with target: CIImage, amount: Double) -> CIImage {
        guard amount > 0.000_1 else { return source }
        guard amount < 0.999_9 else { return target }
        let extent = source.extent.union(target.extent)
        let transparent = CIImage(color: .clear).cropped(to: extent)
        let normalizedSource = source.composited(over: transparent).cropped(to: extent)
        let normalizedTarget = target.composited(over: transparent).cropped(to: extent)
        guard let filter = CIFilter(name: "CIDissolveTransition") else { return target }
        filter.setValue(normalizedSource, forKey: kCIInputImageKey)
        filter.setValue(normalizedTarget, forKey: kCIInputTargetImageKey)
        filter.setValue(amount, forKey: kCIInputTimeKey)
        return (filter.outputImage ?? target).cropped(to: extent)
    }
}
