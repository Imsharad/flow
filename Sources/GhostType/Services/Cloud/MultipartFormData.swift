import Foundation

struct MultipartFormData {
    let boundary: String
    private var data = Data()
    
    init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
    }
    
    mutating func addTextField(named name: String, value: String) {
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(value)\r\n".data(using: .utf8)!)
    }
    
    mutating func addDataField(named name: String, filename: String, contentType: String, data: Data) {
        self.data.append("--\(boundary)\r\n".data(using: .utf8)!)
        self.data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        self.data.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        self.data.append(data)
        self.data.append("\r\n".data(using: .utf8)!)
    }
    
    var bodyData: Data {
        var finalData = data
        finalData.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return finalData
    }
}
