import Combine
import Foundation

protocol UserDefaultsStoreProviding: AnyObject {
    var userDefaultsStore: UserDefaults { get }
}

private func resolvedUserDefaultsStore(
    explicitStore: UserDefaults?,
    enclosingInstance: AnyObject
) -> UserDefaults {
    explicitStore
        ?? (enclosingInstance as? UserDefaultsStoreProviding)?.userDefaultsStore
        ?? .standard
}

// MARK: - PropertyListValue marker

/// UserDefaults에 직접 저장 가능한 plist 타입 마커.
public protocol PropertyListValue {}

extension Bool: PropertyListValue {}
extension Int: PropertyListValue {}
extension Double: PropertyListValue {}
extension Float: PropertyListValue {}
extension String: PropertyListValue {}
extension Data: PropertyListValue {}
extension Date: PropertyListValue {}
extension Array: PropertyListValue where Element: PropertyListValue {}
extension Dictionary: PropertyListValue where Key == String, Value: PropertyListValue {}
extension Optional: PropertyListValue where Wrapped: PropertyListValue {}

/// nil 검사용 헬퍼 — Optional<PropertyListValue>에서 setter가 nil을 감지해 removeObject 호출
private protocol _OptionalProtocol {
    var _isNil: Bool { get }
}

extension Optional: _OptionalProtocol {
    var _isNil: Bool { self == nil }
}

// MARK: - @UserDefault (raw plist types)

/// raw plist 타입(Bool/Int/Double/String/Data/Array/Optional 등)을 UserDefaults에 저장하는 property wrapper.
///
/// `_enclosingInstance` subscript를 통해 `ObservableObject`의 `objectWillChange.send()`를 자동 호출하므로
/// SwiftUI에 변경이 자동 전파된다 (Swift 5.1+ 정식 지원).
@propertyWrapper
public struct UserDefault<Value: PropertyListValue> {
    public let key: String
    public let defaultValue: Value
    private let store: UserDefaults?

    public init(
        key: String,
        defaultValue: Value,
        store: UserDefaults? = nil
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store
    }

    @available(*, unavailable, message: "@UserDefault must be used inside an ObservableObject class")
    public var wrappedValue: Value {
        get { fatalError("@UserDefault requires an enclosing ObservableObject") }
        set { fatalError("@UserDefault requires an enclosing ObservableObject") }
    }

    public static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKP: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKP: ReferenceWritableKeyPath<EnclosingSelf, Self>
    ) -> Value where EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher {
        get {
            let w = instance[keyPath: storageKP]
            let store = resolvedUserDefaultsStore(
                explicitStore: w.store,
                enclosingInstance: instance
            )
            let raw = store.object(forKey: w.key)
            if raw == nil { return w.defaultValue }
            return (raw as? Value) ?? w.defaultValue
        }
        set {
            instance.objectWillChange.send()
            let w = instance[keyPath: storageKP]
            let store = resolvedUserDefaultsStore(
                explicitStore: w.store,
                enclosingInstance: instance
            )
            if let opt = newValue as? _OptionalProtocol, opt._isNil {
                store.removeObject(forKey: w.key)
            } else {
                store.set(newValue, forKey: w.key)
            }
        }
    }
}

// MARK: - @RawRepresentableUserDefault (enums)

/// `RawRepresentable`(주로 enum)을 rawValue로 UserDefaults에 저장하는 property wrapper.
///
/// `rawAliasMap`으로 이전 rawValue를 새 rawValue로 자동 마이그레이션 가능.
/// 예: `["promptEngineering": "fillerRemoval"]` — 이전 "promptEngineering" 값을 읽으면
/// 새 "fillerRemoval"로 해석하여 `CorrectionMode.fillerRemoval` 반환.
@propertyWrapper
public struct RawRepresentableUserDefault<Value: RawRepresentable>
    where Value.RawValue: PropertyListValue, Value.RawValue: Hashable {
    public let key: String
    public let defaultValue: Value
    public let rawAliasMap: [Value.RawValue: Value.RawValue]
    private let store: UserDefaults?

    public init(
        key: String,
        defaultValue: Value,
        rawAliasMap: [Value.RawValue: Value.RawValue] = [:],
        store: UserDefaults? = nil
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.rawAliasMap = rawAliasMap
        self.store = store
    }

    @available(*, unavailable, message: "@RawRepresentableUserDefault must be used inside an ObservableObject class")
    public var wrappedValue: Value {
        get { fatalError("@RawRepresentableUserDefault requires an enclosing ObservableObject") }
        set { fatalError("@RawRepresentableUserDefault requires an enclosing ObservableObject") }
    }

    public static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKP: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKP: ReferenceWritableKeyPath<EnclosingSelf, Self>
    ) -> Value where EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher {
        get {
            let w = instance[keyPath: storageKP]
            let store = resolvedUserDefaultsStore(
                explicitStore: w.store,
                enclosingInstance: instance
            )
            guard let stored = store.object(forKey: w.key) as? Value.RawValue else {
                return w.defaultValue
            }
            let normalized = w.rawAliasMap[stored] ?? stored
            return Value(rawValue: normalized) ?? w.defaultValue
        }
        set {
            instance.objectWillChange.send()
            let w = instance[keyPath: storageKP]
            let store = resolvedUserDefaultsStore(
                explicitStore: w.store,
                enclosingInstance: instance
            )
            store.set(newValue.rawValue, forKey: w.key)
        }
    }
}

// MARK: - @CodableUserDefault (Codable types)

/// `Codable` 값을 JSON Data로 인코딩해 UserDefaults에 저장하는 property wrapper.
/// 주로 `[DomainWordSet]`같은 복합 타입에 사용.
@propertyWrapper
public struct CodableUserDefault<Value: Codable> {
    public let key: String
    public let defaultValue: Value
    private let store: UserDefaults?

    public init(
        key: String,
        defaultValue: Value,
        store: UserDefaults? = nil
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store
    }

    @available(*, unavailable, message: "@CodableUserDefault must be used inside an ObservableObject class")
    public var wrappedValue: Value {
        get { fatalError("@CodableUserDefault requires an enclosing ObservableObject") }
        set { fatalError("@CodableUserDefault requires an enclosing ObservableObject") }
    }

    public static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKP: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKP: ReferenceWritableKeyPath<EnclosingSelf, Self>
    ) -> Value where EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher {
        get {
            let w = instance[keyPath: storageKP]
            let store = resolvedUserDefaultsStore(
                explicitStore: w.store,
                enclosingInstance: instance
            )
            guard let data = store.data(forKey: w.key),
                  let decoded = try? JSONDecoder().decode(Value.self, from: data)
            else { return w.defaultValue }
            return decoded
        }
        set {
            instance.objectWillChange.send()
            let w = instance[keyPath: storageKP]
            let store = resolvedUserDefaultsStore(
                explicitStore: w.store,
                enclosingInstance: instance
            )
            if let data = try? JSONEncoder().encode(newValue) {
                store.set(data, forKey: w.key)
            }
        }
    }
}
