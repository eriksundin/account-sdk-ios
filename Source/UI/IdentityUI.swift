//
// Copyright 2011 - 2018 Schibsted Products & Technology AS.
// Licensed under the terms of the MIT license. See LICENSE in the project root.
//

import SafariServices
import UIKit

/// The UI can start logging in a user either via email or phone number
public enum LoginMethod {
    /// uses email and a one time code to login
    case email
    /// uses email and a one time code to login; the specified email will appear pre-filled in the identity UI, yet the user will still be able to modify it
    /// before submitting.
    case emailWithPrefilledValue(EmailAddress)
    /// uses phone number and a one time code to login
    case phone
    /// uses phone number and a one time code to login; the specified phone number will appear pre-filled in the identity UI, yet the user will still be able to
    /// modify it before submitting.
    case phoneWithPrefilledValue(PhoneNumber)
    /// asks for identifier and then a password to either login or signup if not already registered
    case password
    /// asks for identifier and then a password to either login or signup if not already registered; the specified email will appear pre-filled in the identity
    /// UI, yet the user will still be able to modify it before submitting.
    case passwordWithPrefilledEmail(EmailAddress)

    /// does the user try to signin or signup
    public enum FlowVariant {
        ///
        case signin
        ///
        case signup
    }

    enum AuthenticationType {
        case password
        case passwordless
    }

    enum IdentifierType {
        case email
        case phone
    }

    enum MethodType {
        case email
        case phone
        case password
    }

    var authenticationType: AuthenticationType {
        switch self {
        case .email, .emailWithPrefilledValue, .phone, .phoneWithPrefilledValue:
            return .passwordless
        case .password, .passwordWithPrefilledEmail:
            return .password
        }
    }

    var identifierType: IdentifierType {
        switch self {
        case .email, .emailWithPrefilledValue, .password, .passwordWithPrefilledEmail:
            return .email
        case .phone, .phoneWithPrefilledValue:
            return .phone
        }
    }

    var methodType: MethodType {
        switch self {
        case .email, .emailWithPrefilledValue:
            return .email
        case .phone, .phoneWithPrefilledValue:
            return .phone
        case .password, .passwordWithPrefilledEmail:
            return .password
        }
    }
}

/**
 This is the main IdentityUI object that can be used to create a user object via a UI flow.

 There are two ways to start a login process, you can either start the flow from the beginning
 which will be presented on a provided UIViewController, or you can provide an `IdentityUI.Route`
 that is generally used to continue a flow from the deep link.
 */
public class IdentityUI {
    ///
    public weak var delegate: IdentityUIDelegate?
    ///
    public let configuration: IdentityUIConfiguration
    ///
    public let identityManager: IdentityManager

    let navigationController = UINavigationController()

    var child: ChildFlowCoordinator?

    private let fetchStatusInteractor: FetchStatusInteractor
    private let authenticationCodeInteractor: AuthenticationCodeInteractor

    // Used to store the currently presented identity process so that:
    // 1. The presentation of one process at a time can be enforced.
    // 2. When handling a universal link, the currently presented process (if any) can be retrieved.
    private static var presentedIdentityUI: IdentityUI?

    /**
     Creates an IdentityUI object
     */
    public convenience init(configuration: IdentityUIConfiguration) {
        let manager = IdentityManager(clientConfiguration: configuration.clientConfiguration)
        self.init(configuration: configuration, identityManager: manager)
    }

    /**
     Creates an IdentityUI object with a provided identityManager
     */
    public init(configuration: IdentityUIConfiguration, identityManager: IdentityManager) {
        self.configuration = configuration
        self.identityManager = identityManager
        self.fetchStatusInteractor = FetchStatusInteractor(identityManager: identityManager)
        self.authenticationCodeInteractor = AuthenticationCodeInteractor(identityManager: identityManager)
    }

    /**
     Starts the login process

     Even though multiple `IdentityUI` instances can be constructed, usually only one identity process should be started at a time. An exception to this is
     when the identity process is started as a result of a universal (i.e. deep) link, since in that case it is possible (and somewhat likely) that an existing
     identity process was already in place when the user tapped on a universal links leading her back to the identity process; in that case, calling
     `presentIdentityProcess(from:)` on an instance of `IdentityUI` initialized with a route (e.g. with `init(configuration:route:)`) will automatically handle
     the case of an existing identity process (if any) for you.

     - parameter viewController: which view controller to present the login UI from
     - parameter loginMethod: which login method to use
     - parameter localizedTeaserText: an optional text that will be displayed above the identifier text field in the login screen (may be used to provide the
       user with some context about the login). Text longer than three lines will be truncated with ellipsis. Note that you should supply a localized text.
     - parameter scopes: which scopes you want your logged in user to have accesst to. See `IdentityManager` for more details
     */
    public func presentIdentityProcess(
        from viewController: UIViewController,
        loginMethod: LoginMethod,
        localizedTeaserText: String? = nil,
        scopes: [String] = []
    ) {
        self.configuration.tracker?.loginMethod = loginMethod
        self.start(
            input: .byLoginMethod(
                loginMethod,
                presentingViewController: viewController,
                localizedTeaserText: localizedTeaserText,
                scopes: scopes
            )
        ) { [weak self] output in
            self?.complete(with: output)
        }
    }

    /**
     Starts the login process from a route

     Even though multiple `IdentityUI` instances can be constructed, usually only one identity process should be started at a time. An exception to this is
     when the identity process is started as a result of a universal (i.e. deep) link, since in that case it is possible (and somewhat likely) that an existing
     identity process was already in place when the user tapped on a universal links leading her back to the identity process; in that case, calling
     `presentIdentityProcess(from:)` on an instance of `IdentityUI` initialized with a route (e.g. with `init(configuration:route:)`) will automatically handle
     the case of an existing identity process (if any) for you.

     - parameter viewController: which view controller to present the login UI from
     - parameter route: a parsed `IdentityUI.Route` object

     - SeeAlso: `init(configuration:route:)`
     */
    public func presentIdentityProcess(from viewController: UIViewController, route: Route) {
        self.configuration.tracker?.loginMethod = route.loginMethod
        self.start(input: .byRoute(route, presentingViewController: viewController)) { [weak self] output in
            self?.complete(with: output)
        }
    }

    private func complete(with output: Output) {
        let uiResult: IdentityUIResult?
        switch output {
        case let .success(user):
            self.configuration.tracker?.engagement(.network(.done))
            uiResult = .completed(user)
        case .cancel:
            self.configuration.tracker?.loginID = nil
            uiResult = .canceled
        case .notStarted:
            // Nothing else to do, since the flow was never really started.
            return
        case .onlyDismiss:
            uiResult = nil
        }

        // This is no more the currently presented login flow.
        IdentityUI.presentedIdentityUI = nil

        let finish = { [weak self] in
            if let result = uiResult {
                self?.delegate?.didFinish(result: result)
            }
        }

        if self.navigationController.presentingViewController != nil {
            // It might be that `IdentityUIViewController.endLoading()` has been called just before getting here, in case the result of a networking
            // operation caused the flow to end. The `endLoading()` method will then trigger a `view.isUserInteractionEnabled = true`, which would cause the
            // keyboard to show up again during the dismiss animation, resulting in a very weird and funky UI glitch. In order to avoid that, we force an
            // `endEditing()` on the topmost view (if any) before starting the view dismissing.
            self.navigationController.topViewController?.view.endEditing(true)

            self.navigationController.dismiss(animated: true) {
                finish()
            }
        } else {
            finish()
        }
    }
}

extension IdentityUI: FlowCoordinator {
    enum Input {
        case byLoginMethod(LoginMethod, presentingViewController: UIViewController, localizedTeaserText: String?, scopes: [String])
        case byRoute(Route, presentingViewController: UIViewController)
    }

    enum Output {
        case success(User)
        case cancel
        case notStarted
        case onlyDismiss
    }

    func start(input: Input, completion: @escaping (Output) -> Void) {
        if let presentedIdentityUI = IdentityUI.presentedIdentityUI {
            // A login flow is already in progress. It should not be allowed to have multiple login flows at the same time, but if we ended up here because
            // of a route, we need to give the currently presented login flow a chance to handle it.
            guard case let .byRoute(route, _) = input else {
                preconditionFailure("Attempt to present a new Identity UI instance while another one is already presented.")
            }

            // Let the currently presented flow handle the route.
            presentedIdentityUI.handleRouteForPresentingUI(route: route)

            // This new flow will not be started.
            completion(.notStarted)

            return
        }

        // This is now the currently presented login flow.
        IdentityUI.presentedIdentityUI = self
        // Show the first screen in the flow.
        self.showIdentifierViewController(input: input, completion: completion)
    }
}

extension IdentityUI {
    func showIdentifierViewController(input: Input, completion: @escaping (Output) -> Void) {
        switch input {
        case let .byRoute(route, vc):
            self.handleRouteForUnpresentedUI(route: route, byPresentingIn: vc, completion: completion)
        case let .byLoginMethod(loginMethod, vc, localizedTeaserText, scopes):
            let viewController = self.makeIdentifierViewController(
                loginMethod: loginMethod,
                localizedTeaserText: localizedTeaserText,
                scopes: scopes,
                completion: completion
            )
            self.navigationController.viewControllers = [viewController]
            vc.present(self.navigationController, animated: true)
        }
    }

    private func makeIdentifierViewController(
        loginMethod: LoginMethod,
        localizedTeaserText: String?,
        scopes: [String],
        completion: @escaping (Output) -> Void
    ) -> UIViewController {
        let navigationSettings = NavigationSettings(
            cancel: configuration.isCancelable ? { completion(.cancel) } : nil
        )
        let viewModel = IdentifierViewModel(
            loginMethod: loginMethod,
            localizedTeaserText: localizedTeaserText,
            localizationBundle: self.configuration.localizationBundle
        )
        let viewController = IdentifierViewController(configuration: self.configuration, navigationSettings: navigationSettings, viewModel: viewModel)
        viewController.didRequestAction = { [weak self] action in
            switch action {
            case let .enter(identifier):
                // An identifier was entered: we fetch its status and proceed with the flow accordingly by spawing an appropriate child coordinator.
                self?.fetchFlowVariant(for: identifier) { [weak self] loginFlowVariant in
                    let disposition: LoginFlowDisposition
                    if let delegate = self?.delegate {
                        disposition = delegate.willPresent(flow: loginFlowVariant)
                    } else {
                        disposition = .continue
                    }
                    switch disposition {
                    case .continue:
                        self?.spawnCoordinator(loginMethod.authenticationType, for: identifier, on: loginFlowVariant, scopes: scopes, completion: completion)
                    case let .abort(shouldDismiss):
                        if shouldDismiss {
                            self?.complete(with: .onlyDismiss)
                        }
                    case let .showError(title, description):
                        self?.presentError(title: title, description: description)
                    }
                }
            case let .showHelp(url):
                self?.present(url: url)
            case .back:
                // First screen, `back` cancels the flow.
                completion(.cancel)
            }
        }

        return viewController
    }

    private func fetchFlowVariant(for identifier: Identifier, completion: @escaping (_ loginFlowVariant: LoginMethod.FlowVariant) -> Void) {
        self.presentedViewController?.startLoading()

        self.fetchStatusInteractor.fetchStatus(for: identifier) { [weak self] result in
            self?.presentedViewController?.endLoading()

            switch result {
            case let .success(status):
                let loginFlowVariant: LoginMethod.FlowVariant = status.available ? .signup : .signin
                self?.configuration.tracker?.loginFlowVariant = loginFlowVariant
                completion(loginFlowVariant)
            case let .failure(error):
                if self?.presentedViewController?.showInlineError(error) != true {
                    self?.present(error: error)
                }
            }
        }
    }

    private func spawnCoordinator(
        _ authenticationType: LoginMethod.AuthenticationType,
        for identifier: Identifier,
        on loginFlowVariant: LoginMethod.FlowVariant,
        scopes: [String],
        completion: @escaping (Output) -> Void
    ) {
        let coordinator: AuthenticationCoordinator

        switch authenticationType {
        case .password:
            coordinator = PasswordCoordinator(
                navigationController: self.navigationController,
                identityManager: self.identityManager,
                configuration: self.configuration
            )
        case .passwordless:
            coordinator = PasswordlessCoordinator(
                navigationController: self.navigationController,
                identityManager: self.identityManager,
                configuration: self.configuration
            )
        }

        let input = AuthenticationCoordinator.Input(identifier: identifier, loginFlowVariant: loginFlowVariant, scopes: scopes)
        self.child = ChildFlowCoordinator(coordinator, input: input) { [weak self] output in
            self?.child = nil

            switch output {
            case let .success(user):
                completion(.success(user))
            case .cancel:
                completion(.cancel)
            case .back:
                self?.navigationController.popViewController(animated: true)
            case .changeIdentifier:
                self?.navigationController.popToRootViewController(animated: true)
            case let .reset(error):
                self?.navigationController.popToRootViewController(animated: true)
                if let error = error {
                    self?.present(error: error)
                }
            case let .error(error):
                if let error = error {
                    self?.present(error: error)
                }
            }
        }
    }
}

extension IdentityUI {
    private func handle(route: IdentityUI.Route, byPresentingIn presentingViewController: UIViewController?) {
        switch route {
        case .login:
            // Either we have a child that can handle the route or we have nothing else to do (since we are already in the root, a.k.a. login screen).
            self.attemptToPropagateRouteToChild(route)
        case let .enterPassword(for: email, scopes: scopes):

            if !self.attemptToPropagateRouteToChild(route) {
                // If no child handled the route, we need to present the password screen.

                // The user changed her password after requesting a password change: we present a new login flow with the email prefilled (since we previously
                // saved it on password change request).
                self.spawnCoordinator(.password, for: Identifier(email), on: .signin, scopes: scopes) { [weak self] output in
                    self?.complete(with: output)
                }
            }
        case let .validateAuthCode(code, shouldPersistUser):
            // Let's check if the code validates.
            self.authenticationCodeInteractor.validate(authCode: code, persistUser: shouldPersistUser) { [weak self] result in
                switch result {
                case let .success(user):
                    self?.configuration.tracker?.loginID = self?.identityManager.currentUser.legacyID
                    self?.configuration.tracker?.engagement(.network(.accountVerified))
                    // User has validated the identifier and the code matches, nothing else to do.
                    self?.complete(with: .success(user))
                case let .failure(error):
                    if let navigationController = self?.navigationController, navigationController.presentingViewController == nil {
                        // We don't have a presented flow already, so we go on presenting a new one (just for the sake of presenting the error message).
                        presentingViewController?.present(navigationController, animated: true)
                    }
                    self?.present(error: error)
                }
            }

            // We don't want to present a new login flow yet, since if the verification code validates then we don't need to display any UI.
            return
        }

        if self.navigationController.presentingViewController == nil, let presentingViewController = presentingViewController {
            // We don't have a presented flow already, so we go on presenting a new flow after having handled the route.
            presentingViewController.present(self.navigationController, animated: true)
        }
    }

    private func handleRouteForUnpresentedUI(
        route: IdentityUI.Route,
        byPresentingIn presentingViewController: UIViewController,
        completion: @escaping (Output) -> Void
    ) {
        var scopes: [String]
        switch route {
        case let .enterPassword(_, scopes: storedScopes):
            scopes = storedScopes
        default:
            scopes = []
        }
        let viewController = self.makeIdentifierViewController(loginMethod: route.loginMethod, localizedTeaserText: nil, scopes: scopes, completion: completion)
        self.navigationController.viewControllers = [viewController]
        self.handle(route: route, byPresentingIn: presentingViewController)
    }

    private func handleRouteForPresentingUI(route: IdentityUI.Route) {
        self.handle(route: route, byPresentingIn: nil)
    }

    @discardableResult
    private func attemptToPropagateRouteToChild(_ route: IdentityUI.Route) -> Bool {
        guard let child = self.child else {
            return false
        }
        switch child.handle(route: route) {
        case .handled:
            return true
        case .resetRequest:
            self.child = nil
            self.navigationController.popToRootViewController(animated: true)
            return true
        case .cannotHandle:
            return false
        }
    }
}

extension IdentityUI {
    static let bundle = {
        Bundle(for: IdentityUI.self)
    }()
}
