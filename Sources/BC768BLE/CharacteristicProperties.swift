import CoreBluetooth

extension CBCharacteristicProperties {
    /// Property を人間が読める形式へ変換する。
    public var humanReadable: [String] {
        var names: [String] = []
        if contains(.broadcast) { names.append("broadcast") }
        if contains(.read) { names.append("read") }
        if contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if contains(.write) { names.append("write") }
        if contains(.notify) { names.append("notify") }
        if contains(.indicate) { names.append("indicate") }
        if contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if contains(.extendedProperties) { names.append("extendedProperties") }
        if contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
        if contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
        return names
    }

    public var description: String {
        let names = humanReadable
        return names.isEmpty ? "-" : names.joined(separator: ",")
    }
}
