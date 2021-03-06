//
// Copyright 2011 - 2018 Schibsted Products & Technology AS.
// Licensed under the terms of the MIT license. See LICENSE in the project root.
//

import SchibstedAccount
import UIKit

struct ConfigurationLoader {
    var data: [ClientConfiguration.Environment: EnvData] = [:]

    private typealias JSONData = [String: [String: [String: String]]]

    private mutating func fill(data: JSONData, env: ClientConfiguration.Environment) {
        if let json = data["environment"]?[env.rawValue] {
            let envData = EnvData(
                clientID: json["clientID"] ?? "",
                clientSecret: json["clientSecret"] ?? "",
                clientScheme: json["clientScheme"] ?? "",
                webClientID: json["webClientID"] ?? ""
            )
            self.data[env] = envData
        }
    }

    init() {
        guard let configURL = Bundle.main.url(forResource: "ClientConfiguration", withExtension: "json") else {
            preconditionFailure(
                "The example app uses parameters that need to be decrypted. Please see readme for information on how to get client credentials"
            )
        }
        guard let data = (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL))) as? JSONData else {
            preconditionFailure("Failed to get json data out of ClientConfiguration.json")
        }

        self.fill(data: data, env: .preproduction)
        self.fill(data: data, env: .development)
    }

    struct EnvData {
        var clientID: String = ""
        var clientSecret: String = ""
        var clientScheme: String = ""
        var webClientID: String = ""
    }

    subscript(env: ClientConfiguration.Environment) -> EnvData {
        return self.data[env] ?? EnvData()
    }
}

extension SchibstedAccount.ClientConfiguration {
    static let config = ConfigurationLoader()

    static let preprod = {
        ClientConfiguration(
            environment: .preproduction,
            clientID: config[.preproduction].clientID,
            clientSecret: config[.preproduction].clientSecret,
            appURLScheme: config[.preproduction].clientScheme
        )
    }()

    static let dev = ClientConfiguration(
        environment: .development,
        clientID: config[.development].clientID,
        clientSecret: config[.development].clientSecret,
        appURLScheme: config[.development].clientScheme
    )

    // Set this to what the app should use
    static let current = ClientConfiguration.preprod
}

extension SchibstedAccount.ClientConfiguration {
    var webClientID: String? {
        return ClientConfiguration.config[self.environment!].clientID
    }

    var sdkExampleRedirectURL: URL? {
        if self.clientID == ClientConfiguration.config[.preproduction].clientID {
            return URL(string: "https://pre.sdk-example.com/")
        }
        if self.clientID == ClientConfiguration.config[.development].clientID {
            return URL(string: "https://dev.sdk-example.com/session-exchange-safepage")
        }
        return nil
    }
}

extension IdentityUITheme {
    static let custom: IdentityUITheme = {
        var theme = IdentityUITheme.default
        let image = UIImage(named: "hummus", in: Bundle.main, compatibleWith: nil)
        theme.titleLogo = image
        return theme
    }()
}

extension IdentityUIConfiguration {
    static let current = IdentityUIConfiguration(clientConfiguration: .current, theme: .custom, isCancelable: true)
}

extension UIApplication {
    static var identityManager: IdentityManager {
        return (UIApplication.shared.delegate as! AppDelegate).identityManager // swiftlint:disable:this force_cast
    }
    static var identityUI: IdentityUI {
        return (UIApplication.shared.delegate as! AppDelegate).identityUI // swiftlint:disable:this force_cast
    }
}

private struct InitializeLogger {
    init() {
        Logger.shared.addTransport({ print($0) })
    }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    private let initializeLogger = InitializeLogger()

    var window: UIWindow?
    var offlineMode = false

    let identityManager: IdentityManager = IdentityManager(clientConfiguration: .current)
    lazy var identityUI = {
        IdentityUI(configuration: .current, identityManager: self.identityManager)
    }()

    var passwordFlowViewController: PasswordFlowViewController? {
        // swiftlint:disable:next force_cast
        let tabVC = self.window?.rootViewController! as! UITabBarController
        for case let vc as PasswordFlowViewController in tabVC.childViewControllers {
            return vc
        }
        return nil
    }

    var statusViewController: StatusViewController? {
        // swiftlint:disable:next force_cast
        let tabVC = self.window?.rootViewController! as! UITabBarController
        for case let vc as StatusViewController in tabVC.childViewControllers {
            return vc
        }
        return nil
    }

    func application(_: UIApplication, didFinishLaunchingWithOptions options: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        let urlTypes = Bundle.main.infoDictionary!["CFBundleURLTypes"] as? [[String: Any]]
        let urlSchemes = urlTypes?[0]["CFBundleURLSchemes"] as? [String]
        let clientConfig = SchibstedAccount.ClientConfiguration.current
        if urlSchemes?.contains(clientConfig.appURLScheme) == false {
            print("WARN: Register '\(clientConfig.appURLScheme)' as a custom URL scheme in the Info.plist")
        }

        let doesLaunchOptionsContainRecognizedURL = AppLaunchData(launchOptions: options, clientConfiguration: .current) != nil
        if !doesLaunchOptionsContainRecognizedURL, self.identityManager.currentUser.state == .loggedIn {
            self.ensureAcceptanceOfNewTerms()
            return true
        }

        return true
    }

    private func ensureAcceptanceOfNewTerms() {
        self.identityManager.currentUser.agreements.status { [weak self] result in
            switch result {
            case let .success(hasAcceptedLatestTerms):
                if hasAcceptedLatestTerms {
                    // Latest terms already accepted, nothing else to do.
                    return
                }

                // Fetch the latest terms.
                self?.identityManager.fetchTerms { [weak self] result in
                    switch result {
                    case let .success(terms):
                        // Present UI to accept new terms.
                        guard let viewController = self?.window?.rootViewController, let user = self?.identityManager.currentUser else {
                            return
                        }

                        do {
                            // It is important that you pass the same instance of `User` that you previously stored, otherwise you won't get logout
                            // notifications for that user in case the user is logged out for not having accepted the new terms.
                            try IdentityUI.presentTerms(terms, for: user, from: viewController, configuration: .current)
                        } catch {
                            preconditionFailure("Attempt to initialize IdentityUI with wrong configuration")
                        }
                    case let .failure(error):
                        // Fail silently, retry will occur on next app's launch.
                        print("Error attempting to fetch updated terms: \(error)")
                    }
                }
            case let .failure(error):
                // Fail silently, retry will occur on next app's launch.
                print("Error attempting to fetch availability of new terms: \(error)")
            }
        }
    }

    private func openDeepLink(url: URL, fromSourceApplication _: String?) -> Bool {
        print("The app was opened with a deep link: \(url)")
        guard let payload = ClientConfiguration.current.parseRedirectURL(url) else {
            print("\(url) not a value deep link")
            return false
        }

        if let vc = self.window?.rootViewController, let route = IdentityUI.Route(payload: payload) {
            self.identityUI.presentIdentityProcess(from: vc, route: route)
            return true
        }

        guard let appLaunchData = AppLaunchData(payload: payload) else {
            return false
        }
        switch appLaunchData {
        case .afterForgotPassword:
            print("enter password now")
        case let .codeAfterSignup(code, shouldPersistUser):
            self.passwordFlowViewController?.validateDeepLinkCode(code, persistUser: shouldPersistUser)
        case let .codeAfterUnvalidatedLogin(code):
            self.passwordFlowViewController?.validateDeepLinkCode(code, persistUser: false)
        }
        return true
    }

    // called by OS to open a deep link (iOS 9+ compatible)
    func application(_: UIApplication, open url: URL, options: [UIApplicationOpenURLOptionsKey: Any] = [:]) -> Bool {
        let sourceApplication = options[UIApplicationOpenURLOptionsKey.sourceApplication] as? String
        return openDeepLink(url: url, fromSourceApplication: sourceApplication)
    }

    func applicationWillResignActive(_: UIApplication) {
        // Sent when the application is about to move from active to inactive state.
        // This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message)
        // or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates.
        // Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers,
        // and store enough application state information to restore your application to its current state in
        // case it is terminated later.
        // If your application supports background execution, this method is called instead of
        // applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_: UIApplication) {
        // Called as part of the transition from the background to the inactive state; here you can undo many of the
        // changes made on entering the background.
    }

    func applicationDidBecomeActive(_: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the
        // application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate.
        // See also applicationDidEnterBackground:.
    }
}
