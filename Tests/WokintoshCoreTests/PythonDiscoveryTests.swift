import Foundation
import XCTest
@testable import WokintoshCore

final class PythonDiscoveryTests:XCTestCase {
    func testVersionedPythonOnSSHPathIsFoundWhenPython3IsTooOld() throws {
        let fixture=try ProbeFixture();defer{fixture.remove()}
        try fixture.python(at:fixture.bin.appendingPathComponent("python3"),version:"3,9,6")
        let newer=fixture.bin.appendingPathComponent("python3.12")
        try fixture.python(at:newer,version:"3,12,16")
        let result=try fixture.probe()
        XCTAssertEqual(result.status,0)
        guard result.status==0 else{return}
        let data=try XCTUnwrap(result.output.data(using:.utf8))
        let record=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        XCTAssertEqual(record["python"] as? String,newer.path)
        XCTAssertEqual(record["version"] as? [Int],[3,12,16])
    }
    func testHomebrewKegOnlyPythonIsFoundWithoutChangingSSHPath() throws {
        let fixture=try ProbeFixture();defer{fixture.remove()}
        try fixture.python(at:fixture.bin.appendingPathComponent("python3"),version:"3,9,6")
        let newer=fixture.root.appendingPathComponent("homebrew/opt/python@3.12/bin/python3.12")
        try fixture.python(at:newer,version:"3,12,16")
        let result=try fixture.probe()
        XCTAssertEqual(result.status,0)
        if result.status==0 {
            let record=try JSONSerialization.jsonObject(with:Data(result.output.utf8)) as! [String:Any]
            XCTAssertEqual(record["python"] as? String,newer.path)
        }
    }

    func testCompatiblePython3KeepsPriorityOverOtherInstalledVersions() throws {
        let fixture=try ProbeFixture();defer{fixture.remove()}
        let preferred=fixture.bin.appendingPathComponent("python3")
        try fixture.python(at:preferred,version:"3,11,9")
        try fixture.python(at:fixture.bin.appendingPathComponent("python3.12"),version:"3,12,16")
        let result=try fixture.probe()
        XCTAssertEqual(result.status,0)
        guard result.status==0 else{return}
        let record=try JSONSerialization.jsonObject(with:Data(result.output.utf8)) as! [String:Any]
        XCTAssertEqual(record["python"] as? String,preferred.path)
        XCTAssertEqual(record["version"] as? [Int],[3,11,9])
    }
    func testPythonOrgFrameworkInstallationIsFoundOutsideSSHPath() throws {
        let fixture=try ProbeFixture();defer{fixture.remove()}
        try fixture.python(at:fixture.bin.appendingPathComponent("python3"),version:"3,9,6")
        let newer=fixture.root.appendingPathComponent("frameworks/Python.framework/Versions/3.12/bin/python3.12")
        try fixture.python(at:newer,version:"3,12,16")
        let result=try fixture.probe()
        XCTAssertEqual(result.status,0)
        guard result.status==0 else{return}
        let record=try JSONSerialization.jsonObject(with:Data(result.output.utf8)) as! [String:Any]
        XCTAssertEqual(record["python"] as? String,newer.path)
    }
    func testOldPythonAndConfigHelpersAreNotAcceptedAsInterpreters() throws {
        let fixture=try ProbeFixture();defer{fixture.remove()}
        try fixture.python(at:fixture.bin.appendingPathComponent("python3"),version:"3,9,6")
        try fixture.python(at:fixture.bin.appendingPathComponent("python3.12-config"),version:"3,12,16")
        let result=try fixture.probe()
        XCTAssertEqual(result.status,1)
        XCTAssertTrue(result.output.isEmpty)
    }

    func testInterpreterWithSpacesIsSkippedForUsableFallback() throws {
        let fixture=try ProbeFixture();defer{fixture.remove()}
        try fixture.python(at:fixture.bin.appendingPathComponent("python3"),version:"3,9,6")
        let spaced=fixture.root.appendingPathComponent("versioned path")
        try fixture.python(at:spaced.appendingPathComponent("python3.12"),version:"3,12,16")
        let usable=fixture.root.appendingPathComponent("homebrew/bin/python3.12")
        try fixture.python(at:usable,version:"3,12,16")
        let result=try fixture.probe(extraPath:spaced)
        XCTAssertEqual(result.status,0)
        guard result.status==0 else{return}
        let record=try JSONSerialization.jsonObject(with:Data(result.output.utf8)) as! [String:Any]
        XCTAssertEqual(record["python"] as? String,usable.path)
    }

    private final class Capture:@unchecked Sendable {var command:String?}
    private final class ProbeFixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("wokintosh-python-"+UUID().uuidString)
        var bin:URL {root.appendingPathComponent("ssh-bin")}
        init()throws {try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)}
        func remove() {try? FileManager.default.removeItem(at:root)}
        func python(at path:URL,version:String)throws {
            try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
            // Run the actual generated version probe using a controlled interpreter identity.
            let code="import json,os,sys;sys.version_info=("+version+");sys.executable=sys.argv[1];exec(sys.argv[3])"
            let script="#!/bin/sh\nexec /usr/bin/python3 -c "+RemoteCommand.shellQuote(code)+" \"$0\" \"$@\"\n"
            try script.write(to:path,atomically:true,encoding:.utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path)
        }
        func probe(extraPath:URL?=nil)throws->(status:Int32,output:String) {
            let capture=Capture()
            _=try? RemoteInstall.run(destination:"fixture-only",collectorPath:"~/bin/agent",localCollectorPath:"/tmp/unused",runner:{command in
                capture.command=command.arguments.last
                throw RunnerError.failed("Probe captured; no SSH or installation runs")
            })
            var command=try XCTUnwrap(capture.command)
            // Redirect absolute installation prefixes to the fixture so the test host's Python cannot mask a discovery failure.
            for (prefix,relative) in [("/opt/homebrew","homebrew"),("/usr/local","local"),("/usr/bin","system"),("/Library/Frameworks","frameworks")] {
                command=command.replacingOccurrences(of:prefix,with:root.appendingPathComponent(relative).path)
            }
            let process=Process(),output=Pipe()
            process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=["-c",command]
            process.environment=["PATH":bin.path+(extraPath.map{":"+$0.path} ?? "")+":/bin","HOME":root.path]
            process.standardOutput=output;process.standardError=FileHandle.nullDevice
            try process.run();process.waitUntilExit()
            return(process.terminationStatus,String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? "")
        }
    }
}
