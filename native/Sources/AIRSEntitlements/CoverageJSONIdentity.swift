import Foundation

/// Adapted from owned EntitlementDiff BoundedJSON: retain exact UTF-8 object keys
/// and strings, and Python integer-vs-float configuration semantics. This is a
/// configuration identity parser, not a new report or instruction interpreter.
indirect enum CoverageJSONIdentity:Equatable,Sendable {
    case object([Data:CoverageJSONIdentity]),array([CoverageJSONIdentity]),string(Data),number(String),boolean(Bool),null
    subscript(_ key:String)->Self? {guard case .object(let fields)=self else {return nil};return fields[Data(key.utf8)]}
    var array:[Self]? {guard case .array(let values)=self else {return nil};return values}
    static func parse(_ bytes:Data) throws -> Self {var parser=CoverageIdentityParser(bytes);return try parser.parse()}
}
private struct CoverageIdentityParser {
    let bytes:[UInt8]
    var position=0,nodes=0
    init(_ data:Data) {bytes=Array(data)}
    mutating func whitespace() {while position < bytes.count && [9,10,13,32].contains(bytes[position]) {position += 1}}
    mutating func take(_ byte:UInt8)->Bool {whitespace();if position < bytes.count && bytes[position] == byte {position += 1;return true};return false}
    mutating func parse() throws -> CoverageJSONIdentity {let value=try node(0);whitespace();guard position == bytes.count else {throw InspectionArchiveError.invalid};return value}
    mutating func string() throws -> Data {
        whitespace();let start=position;guard take(34) else {throw InspectionArchiveError.invalid}
        while position < bytes.count {
            let byte=bytes[position];position += 1
            if byte == 92 {guard position < bytes.count else {throw InspectionArchiveError.invalid};position += 1}
            else if byte == 34 {
                let value=Data(try JSONDecoder().decode(String.self,from:Data(bytes[start..<position])).utf8)
                guard value.count <= 1_048_576 else {throw InspectionArchiveError.limit};return value
            }
        }
        throw InspectionArchiveError.invalid
    }
    mutating func node(_ depth:Int) throws -> CoverageJSONIdentity {
        whitespace();nodes += 1
        guard depth <= 96,nodes <= 100_000 else {throw InspectionArchiveError.limit}
        guard position < bytes.count else {throw InspectionArchiveError.invalid}
        if take(123) {
            var fields:[Data:CoverageJSONIdentity]=[:]
            if take(125) {return .object(fields)}
            repeat {
                let key=try string();guard fields[key] == nil,take(58) else {throw InspectionArchiveError.invalid}
                fields[key]=try node(depth+1);if take(125) {return .object(fields)}
            } while take(44)
            throw InspectionArchiveError.invalid
        }
        if take(91) {
            var values:[CoverageJSONIdentity]=[]
            if take(93) {return .array(values)}
            repeat {values.append(try node(depth+1));if take(93) {return .array(values)}} while take(44)
            throw InspectionArchiveError.invalid
        }
        if bytes[position] == 34 {return .string(try string())}
        let start=position
        while position < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[position]) {position += 1}
        let token=Data(bytes[start..<position]),text=String(decoding:token,as:UTF8.self)
        switch text {case "true":return .boolean(true);case "false":return .boolean(false);case "null":return .null;default:break}
        let value=try JSONDecoder().decode(Double.self,from:token);guard value.isFinite else {throw InspectionArchiveError.invalid}
        if text.contains(".") || text.contains("e") || text.contains("E") {return .number("float:"+String(value.bitPattern))}
        return .number("integer:"+(text == "-0" ? "0":text))
    }
}
