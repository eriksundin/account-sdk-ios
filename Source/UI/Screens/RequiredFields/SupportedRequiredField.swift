//
// Copyright 2011 - 2018 Schibsted Products & Technology AS.
// Licensed under the terms of the MIT license. See LICENSE in the project root.
//

import Foundation

/**
 The UI currently has support for the following fields and types
 */
enum SupportedRequiredField: String {
    case givenName
    case familyName
    case birthday

    static func from(_ requiredFields: [RequiredField]) -> [SupportedRequiredField] {
        return requiredFields.compactOrFlatMap { field in
            field.supportedField
        }
    }

    func format(oldValue: String, with newValue: String) -> String {
        switch self {
        case .birthday:
            // If backspace when input displays a dash, then since we add a dash automagically
            // we remove the dash and the previous char for symmetry
            if newValue.count == oldValue.count - 1 && oldValue.last == "-" {
                return String(newValue.dropLast())
            }

            var string = newValue.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)

            // YYY
            if string.count < 4 {
                return string
            }
            // YYYY -> YYYY-
            string.insert("-", at: string.index(string.startIndex, offsetBy: 4))

            // YYYY-M
            if string.count < 7 {
                return string
            }

            // YYYY-MM -> // YYYY-MM-
            string.insert("-", at: string.index(string.startIndex, offsetBy: 7))

            // YYYY-MM-DD
            return String(string.prefix(10))
        case .familyName, .givenName:
            return newValue
        }
    }

    enum ValidationError {
        case missing
        case lessThanThree
        case dateInvalid
    }

    func validate(value: String) -> ValidationError? {
        if value.isEmpty {
            return .missing
        }
        switch self {
        case .familyName, .givenName:
            if value.count < 3 {
                return .lessThanThree
            }
        case .birthday:
            guard case .full? = Birthdate(string: value) else {
                return .dateInvalid
            }
        }
        return nil
    }

    var allowsCursorMotion: Bool {
        switch self {
        case .familyName, .givenName:
            return true
        case .birthday:
            return false
        }
    }
}

private extension RequiredField {
    var supportedField: SupportedRequiredField? {
        switch self {
        case .givenName:
            return .givenName
        case .familyName:
            return .familyName
        case .birthday:
            return .birthday
        case .displayName:
            return nil
        }
    }
}

extension UserProfile {
    mutating func set(field: SupportedRequiredField, value: String) {
        switch field {
        case .givenName:
            self.givenName = value
        case .familyName:
            self.familyName = value
        case .birthday:
            self.birthday = Birthdate(string: value)
        }
    }
}
