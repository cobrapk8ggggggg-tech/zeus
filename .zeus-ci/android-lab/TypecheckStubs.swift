import Foundation
import Combine
struct ZeusPatch { static func failure(_ value:String)->NSError { NSError(domain:"fixture",code:1,userInfo:[NSLocalizedDescriptionKey:value]) } }
@MainActor enum NativeCloudAccountAPI { static var ownerID:String? }
@MainActor final class ZeusGitHubTools {
 static let shared=ZeusGitHubTools()
 func object(accountID:String,path:String,query:[String:String]=[:]) async throws->[String:Any] { [:] }
 func request(accountID:String,method:String="GET",path:String,query:[String:String]=[:],body:[String:Any]?=nil) async throws->[String:Any] { [:] }
 func readSource(accountID:String,repository:String,branch:String,path:String,offset:Int=0,maxChars:Int=8000) async throws->[String:Any] { [:] }
 func writeSources(accountID:String,repository:String,branch:String,message:String,files:[[String:Any]]) async throws->[String:Any] { [:] }
 func downloadArtifact(accountID:String,repository:String,artifactID:Int) async throws->URL { URL(fileURLWithPath:"/unused") }
}
struct ZeusLinkedAccount:Identifiable { let id:String;let label:String;let isDefault:Bool }
@MainActor final class ZeusConnections:ObservableObject { static let shared=ZeusConnections();func linked(_ provider:String)->[ZeusLinkedAccount] { [] } }
enum BackupZipExtractor {
 struct Entry { let name:String;let uncompressedSize:Int;let compressedSize:Int }
 static func centralDirectory(handle:FileHandle)throws->[Entry] { [] }
}
enum BackupPackageReader { static func readEntry(at url:URL,named:String)throws->Data? { nil } }
enum ZeusAndroidAPKTransfer { struct Uploaded { let project:String;let sha256:String } }
enum ZeusAndroidTools { static let names:Set<String>=["android_device","android_ui","android_screenshot","android_network","android_project"] }
