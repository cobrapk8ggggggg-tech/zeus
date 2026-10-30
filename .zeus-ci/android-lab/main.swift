import Foundation
import CryptoKit
let directory=URL(fileURLWithPath:CommandLine.arguments[1])
let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("fixture.json"))) as! [String:Any]
let session=UUID(uuidString:fixture["session"] as! String)!
let key=Data(base64Encoded:fixture["private_key"] as! String)!
let encoded=try JSONSerialization.data(withJSONObject:fixture["box"]!)
let box=try JSONDecoder().decode(ZeusLabEnvelope.Box.self,from:encoded)
let text=try ZeusLabEnvelope.open(box,using:key,session:session)
precondition(String(decoding:text,as:UTF8.self)=="Actual Python to Swift crypto compatibility · مرحبا")
let recipient=try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:key)
let response=try ZeusLabEnvelope.seal(Data("Actual Swift to Python crypto compatibility · مرحبا".utf8),to:recipient.publicKey.rawRepresentation.base64EncodedString(),session:session)
try JSONEncoder().encode(response).write(to:directory.appendingPathComponent("swift-box.json"))
var denied=false
do { _ = try ZeusLabEnvelope.open(box,using:key,session:UUID()) } catch { denied=true }
precondition(denied,"A different laboratory session must be rejected")
print("PASS Python → Swift decryption and foreign-session rejection; wrote Swift → Python ciphertext")
