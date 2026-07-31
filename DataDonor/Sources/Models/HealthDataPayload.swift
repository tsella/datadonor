import Foundation

struct HealthDataPayload: Codable {
    let deviceId: String
    let syncTimestamp: String
    let data: [HealthDataPoint]
    
    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case syncTimestamp = "sync_timestamp"
        case data
    }
}

struct HealthDataPoint: Codable {
    let type: String
    let value: HealthDataValue
    let unit: String?
    let startDate: String
    let endDate: String
    let source: String
    
    enum CodingKeys: String, CodingKey {
        case type
        case value
        case unit
        case startDate = "start_date"
        case endDate = "end_date"
        case source
    }
}

enum HealthDataValue: Codable {
    case string(String)
    case double(Double)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else {
            throw DecodingError.typeMismatch(
                HealthDataValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected String or Double")
            )
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let stringValue):
            try container.encode(stringValue)
        case .double(let doubleValue):
            try container.encode(doubleValue)
        }
    }
}
