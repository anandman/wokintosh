import importlib.util, json, tempfile, unittest, os, subprocess, sys
from unittest.mock import patch
from datetime import datetime, timezone, timedelta
from pathlib import Path

spec = importlib.util.spec_from_file_location("collector", Path(__file__).parents[1] / "wokintosh_agent.py")
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 10, 29, 22, 0, tzinfo=timezone.utc)
STAMP = NOW.isoformat()

class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()
    def log(self, name, records, extra=""):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(r)+"\n" for r in records)+extra)
        return path
    def codex(self, identity="a", event="task_started"):
        return [{"type":"session_meta","payload":{"id":identity,"cwd":"/src/project"},"timestamp":STAMP}, {"type":"event_msg","payload":{"type":event},"timestamp":STAMP}]
    def test_malformed_parent_metadata_keeps_healthy_snapshot_decodable(self):
        self.log(".codex/sessions/healthy.jsonl", self.codex("healthy"))
        for index, parent in enumerate([{"unexpected": "object"}, ["array"], 12, "  parent\n  id  ", "x" * 240]):
            rows = self.codex(f"child-{index}")
            rows[0]["payload"]["source"] = {"subagent": {"thread_spawn": {"parent_thread_id": parent}}}
            self.log(f".codex/sessions/child-{index}.jsonl", rows)
        for poll in range(2):
            snapshot = agent.make_snapshot(self.root, self.root/"state", NOW)
            sessions = {item["id"]: item for item in snapshot["sessions"]}
            self.assertEqual(len(sessions), 6)
            self.assertEqual(sessions["healthy"]["state"], "working")
            for index, expected in enumerate([None, None, None, "parent id", "x" * 180]):
                self.assertEqual(sessions[f"child-{index}"]["parentId"], expected)
            self.assertTrue(all(agent.valid_session(item) is not None for item in sessions.values()))
            # This is the String? contract required by the Swift Snapshot decoder.
            self.assertTrue(all(item["parentId"] is None or isinstance(item["parentId"], str) for item in sessions.values()))

    def test_invalid_fresh_parse_is_not_cached_or_emitted(self):
        self.log(".codex/sessions/healthy.jsonl", self.codex("healthy"))
        invalid = agent.base_session("bad", "codex", "", NOW)
        invalid["state"] = {"invalid": "state"}
        with patch.object(agent, "read_codex", return_value=invalid):
            snapshot = agent.make_snapshot(self.root, self.root/"state", NOW)
        self.assertEqual(snapshot["sessions"], [])
        entries = json.loads((self.root/"state/parse-cache.json").read_text())["entries"]
        self.assertTrue(all(entry["session"] is None for entry in entries.values()))

    def test_codex_started_session_is_working(self):
        result=agent.read_codex(self.log("a.jsonl",self.codex()),NOW)
        self.assertIsNotNone(result)
        self.assertEqual(result["state"],"working")
        self.assertEqual(result["id"],"a")
        self.assertEqual(result["provider"],"codex")
    def test_codex_completion_and_partial_record(self):
        result=agent.read_codex(self.log("a.jsonl",self.codex(event="task_complete"),'{"type":'),NOW)
        self.assertIsNotNone(result)
        self.assertEqual(result["state"],"finished")
    def test_stale_work_is_unknown_instead_of_working_forever(self):
        result=agent.read_codex(self.log("a.jsonl",self.codex()),NOW+timedelta(hours=3))
        self.assertIsNotNone(result)
        self.assertEqual(result["state"],"unknown")
    def test_claude_custom_title_and_end_turn(self):
        records=[{"type":"custom-title","customTitle":"Review auth","sessionId":"c"},{"type":"assistant","sessionId":"c","cwd":"/src/project","timestamp":STAMP,"message":{"stop_reason":"end_turn","content":[{"type":"text","text":"private body must never be returned"}]}}]
        result=agent.read_claude(self.log("c.jsonl",records),NOW)
        self.assertIsNotNone(result)
        self.assertEqual(result["title"],"Review auth")
        self.assertEqual(result["state"],"finished")
        self.assertNotIn("private body",json.dumps(result))
    def test_claude_tool_use_stays_working(self):
        result=agent.read_claude(self.log("c.jsonl",[{"type":"assistant","sessionId":"c","timestamp":STAMP,"message":{"stop_reason":"tool_use"}}]),NOW)
        self.assertIsNotNone(result)
        self.assertEqual(result["state"],"working")
    def test_hook_attention_and_resume_transitions(self):
        result=agent.apply_hook_state({"id":"a","provider":"codex","state":"working"},{"hook_event_name":"PermissionRequest","session_id":"a"},NOW)
        self.assertIsNotNone(result)
        self.assertEqual(result["state"],"needsAttention")
        resumed=agent.apply_hook_state(result,{"hook_event_name":"PreToolUse","session_id":"a"},NOW)
        self.assertEqual(resumed["state"],"working")
    def test_snapshot_keeps_multiple_sessions_and_both_providers(self):
        self.log(".codex/sessions/a.jsonl",self.codex("a"))
        self.log(".codex/sessions/b.jsonl",self.codex("b"))
        for identity in ("c","d"):
            self.log(f".claude/projects/project/{identity}.jsonl",[{"type":"user","sessionId":identity,"cwd":"/src/project","timestamp":STAMP,"message":{"content":"a private prompt"}}])
        result=agent.make_snapshot(self.root,self.root/"state",NOW,host_name="Test Mac")
        self.assertIsNotNone(result)
        self.assertEqual(len(result["sessions"]),4)
        self.assertEqual({x["id"] for x in result["sessions"]},{"a","b","c","d"})
        self.assertEqual(result["schemaVersion"],1)
        self.assertNotIn("a private prompt",json.dumps(result))
    def test_hook_config_preserves_existing_and_is_idempotent(self):
        existing={"other":"preserved","hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-hook"}]}]}}
        result=agent.hook_install_config("claude","/safe/collector hook --provider claude",existing)
        self.assertIsNotNone(result)
        self.assertEqual(result["other"],"preserved")
        self.assertEqual(result["hooks"]["Stop"][0]["hooks"][0]["command"],"existing-hook")
        again=agent.hook_install_config("claude","/safe/collector hook --provider claude",result)
        self.assertEqual(result,again)
    def test_malformed_log_does_not_become_a_fake_session(self):
        result=agent.read_codex(self.log("bad.jsonl",[],"junk\n{\n"),NOW)
        self.assertIsNone(result)


    def test_helper_events_do_not_change_parent_without_identity(self):
        parent = {"id":"a","provider":"claude","state":"needsAttention","updatedAt":STAMP}
        for name in ("SubagentStart", "SubagentStop"):
            self.assertEqual(agent.apply_hook_state(parent,{"hook_event_name":name},NOW),parent)
            agent.ingest_hook("claude", {"session_id":"a","hook_event_name":name},self.root,self.root/"state",NOW)
        self.assertEqual(list((self.root/"state/hooks").glob("*.json")),[])

    def test_child_hook_identity_preserves_parent_state(self):
        state = self.root/"state"
        for provider in ("claude", "codex"):
            agent.ingest_hook(provider,{"session_id":"parent","hook_event_name":"PermissionRequest"},self.root,state,NOW)
            agent.ingest_hook(provider,{"session_id":"parent","agent_id":"child","hook_event_name":"SubagentStop"},self.root,state,NOW)
        sessions=agent.make_snapshot(self.root,state,NOW)["sessions"]
        parents=[s for s in sessions if s["id"]=="parent"]
        children=[s for s in sessions if s.get("parentId")=="parent"]
        self.assertEqual(len(parents),2)
        self.assertTrue(all(s["state"]=="needsAttention" for s in parents))
        self.assertEqual(len(children),2)
        self.assertTrue(all(s["state"]=="finished" for s in children))

    def test_newer_hook_keeps_transcript_metadata(self):
        rows=self.codex("a")
        rows[0]["payload"].update(title="Custom parent",source={"subagent":{"thread_spawn":{"parent_thread_id":"ancestor"}}})
        self.log(".codex/sessions/a.jsonl",rows)
        agent.ingest_hook("codex",{"session_id":"a","hook_event_name":"PermissionRequest"},self.root,self.root/"state",NOW+timedelta(seconds=2))
        result=agent.make_snapshot(self.root,self.root/"state",NOW+timedelta(seconds=3))["sessions"][0]
        self.assertEqual(result["state"],"needsAttention")
        self.assertEqual((result["title"],result["project"],result["parentId"]),("Custom parent","project","ancestor"))

    def test_parallel_output_does_not_clear_pending_input(self):
        rows=self.codex()+[
            {"type":"response_item","timestamp":STAMP,"payload":{"type":"function_call","name":"request_user_input","call_id":"input-1"}},
            {"type":"response_item","timestamp":STAMP,"payload":{"type":"function_call_output","call_id":"parallel"}}]
        path=self.log("a.jsonl",rows)
        self.assertEqual(agent.read_codex(path,NOW)["state"],"needsAttention")
        rows.append({"type":"response_item","timestamp":STAMP,"payload":{"type":"function_call_output","call_id":"input-1"}})
        self.assertEqual(agent.read_codex(self.log("a.jsonl",rows),NOW)["state"],"working")

    def test_all_pending_inputs_must_finish(self):
        rows=self.codex()
        for identity in ("one","two"):
            rows.append({"type":"response_item","timestamp":STAMP,"payload":{"type":"custom_tool_call","name":"mcp__request_user_input","call_id":identity}})
        rows.append({"type":"response_item","timestamp":STAMP,"payload":{"type":"custom_tool_call_output","call_id":"one"}})
        self.assertEqual(agent.read_codex(self.log("a.jsonl",rows),NOW)["state"],"needsAttention")

    def test_input_without_call_id_stays_attention_after_output(self):
        rows=self.codex()+[{"type":"event_msg","timestamp":STAMP,"payload":{"type":"request_user_input"}},
                           {"type":"response_item","timestamp":STAMP,"payload":{"type":"function_call_output","call_id":"other"}}]
        self.assertEqual(agent.read_codex(self.log("a.jsonl",rows),NOW)["state"],"needsAttention")

    def test_scan_gap_does_not_keep_old_completed_turn(self):
        rows=self.codex(event="task_complete")
        rows.append({"type":"padding","payload":{"text":"x"*(agent.MAX_LOG_BYTES+100)}})
        rows.append({"type":"response_item","timestamp":STAMP,"payload":{"type":"reasoning","summary":[{"text":"private reasoning"}]}})
        result=agent.read_codex(self.log("large.jsonl",rows),NOW)
        self.assertEqual(result["state"],"working")
        self.assertNotIn("private reasoning",json.dumps(result))

    def test_scan_gap_with_ambiguous_tail_is_unknown(self):
        rows=self.codex(event="task_complete")+[{"type":"padding","payload":{"text":"x"*(agent.MAX_LOG_BYTES+100)}},
            {"type":"event_msg","timestamp":STAMP,"payload":{"type":"token_count"}}]
        self.assertEqual(agent.read_codex(self.log("large.jsonl",rows),NOW)["state"],"unknown")

    def test_recent_explicit_completion_wins_after_gap(self):
        rows=self.codex()+[{"type":"padding","payload":{"text":"x"*(agent.MAX_LOG_BYTES+100)}},
            {"type":"event_msg","timestamp":STAMP,"payload":{"type":"task_complete"}}]
        self.assertEqual(agent.read_codex(self.log("large.jsonl",rows),NOW)["state"],"finished")

    def test_working_hook_ages_to_unknown(self):
        agent.ingest_hook("claude",{"session_id":"a","hook_event_name":"PreToolUse"},self.root,self.root/"state",NOW)
        result=agent.make_snapshot(self.root,self.root/"state",NOW+timedelta(hours=2))["sessions"][0]
        self.assertEqual(result["state"],"unknown")

    def test_hook_installer_registers_completion_and_child_signals(self):
        for provider in ("claude","codex"):
            config=agent.hook_install_config(provider,"safe hook",{})
            self.assertIn("PostToolUse",config["hooks"])
            self.assertIn("SubagentStart",config["hooks"])

    def test_cli_hooks_are_neutral_and_install_preserves_temporary_home(self):
        script=str(Path(agent.__file__).resolve())
        state=self.root/"state"
        settings=self.root/".claude/settings.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"keep":True,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing"}]}]}}))
        before=settings.read_text()
        args=[sys.executable,script,"--home",str(self.root),"--state-dir",str(state)]
        for _ in range(2):
            subprocess.run(args+["install-hooks","--provider","claude"],capture_output=True,text=True,check=True,timeout=10)
        self.assertEqual(json.loads(settings.read_text())["hooks"]["Stop"][0]["hooks"][0]["command"],"existing")
        self.assertIn(before,[p.read_text() for p in settings.parent.glob("*.wokintosh-backup-*")])
        result=subprocess.run(args+["hook","--provider","claude"],input=json.dumps({"session_id":"a","hook_event_name":"PermissionRequest","tool_input":{"private":"body"}}),capture_output=True,text=True,check=True,timeout=10)
        self.assertEqual(result.stdout.strip(),"{}")
        self.assertNotIn("private",''.join(p.read_text() for p in (state/"hooks").glob("*.json")))

    def test_cache_reuses_unchanged_parse_across_module_instances_and_ages(self):
        self.log(".codex/sessions/a.jsonl",self.codex())
        state=self.root/"state"
        agent.make_snapshot(self.root,state,NOW)
        other=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(other)
        # Parsing is the costly operation; filesystem/discovery and actual snapshot stay real.
        with patch.object(other,"read_codex",side_effect=AssertionError("unchanged log reparsed")):
            result=other.make_snapshot(self.root,state,NOW+timedelta(hours=2))
        self.assertEqual(result["sessions"][0]["state"],"unknown")

    def test_cache_updates_title_and_changed_transcript(self):
        self.log(".codex/sessions/a.jsonl",self.codex())
        state=self.root/"state"
        agent.make_snapshot(self.root,state,NOW)
        self.log(".codex/session_index.jsonl",[{"id":"a","thread_name":"Renamed"}])
        self.log(".codex/sessions/a.jsonl",self.codex(event="task_complete"))
        result=agent.make_snapshot(self.root,state,NOW)["sessions"][0]
        self.assertEqual((result["title"],result["state"]),("Renamed","finished"))

    def test_persistent_cache_is_bounded_body_free_and_recovers_corruption(self):
        self.log(".codex/sessions/a.jsonl",self.codex()+[{"type":"response_item","payload":{"type":"reasoning","text":"SECRET BODY"},"timestamp":STAMP}])
        state=self.root/"state"
        agent.make_snapshot(self.root,state,NOW)
        path=state/"parse-cache.json"
        self.assertTrue(path.exists())
        self.assertLess(path.stat().st_size,1024*1024)
        self.assertNotIn("SECRET BODY",path.read_text())
        path.write_text('{"entries":')
        self.assertEqual(len(agent.make_snapshot(self.root,state,NOW)["sessions"]),1)
        self.assertIsInstance(json.loads(path.read_text()),dict)


    def test_structurally_corrupt_cache_reparses_instead_of_hiding_session(self):
        self.log(".codex/sessions/a.jsonl",self.codex())
        state=self.root/"state"
        agent.make_snapshot(self.root,state,NOW)
        path=state/"parse-cache.json"
        self.assertTrue(path.exists())
        data=json.loads(path.read_text())
        next(iter(data["entries"].values()))["session"]["state"]=[]
        path.write_text(json.dumps(data))
        self.assertEqual(len(agent.make_snapshot(self.root,state,NOW)["sessions"]),1)

    def test_child_id_equal_to_parent_does_not_finish_parent(self):
        state=self.root/"state"
        agent.ingest_hook("codex",{"session_id":"a","hook_event_name":"PermissionRequest"},self.root,state,NOW)
        agent.ingest_hook("codex",{"session_id":"a","agent_id":"a","hook_event_name":"SubagentStop"},self.root,state,NOW)
        self.assertEqual(agent.make_snapshot(self.root,state,NOW)["sessions"][0]["state"],"needsAttention")

    def test_installed_command_keeps_explicit_home_and_state_directory(self):
        state=self.root/"state"
        script=str(Path(agent.__file__).resolve())
        result=subprocess.run([sys.executable,script,"--home",str(self.root),"--state-dir",str(state),"install-hooks","--provider","codex","--dry-run"],capture_output=True,text=True,check=True,timeout=10)
        command=json.loads(result.stdout)["hooks"]["Stop"][0]["hooks"][0]["command"]
        import shlex
        args=shlex.split(command, comments=True)
        self.assertIn(str(self.root),args)
        self.assertIn(str(state),args)
        observed=subprocess.run(args,input=json.dumps({"session_id":"a","hook_event_name":"Stop"}),capture_output=True,text=True,check=True,timeout=10)
        self.assertEqual(observed.stdout.strip(),"{}")
        self.assertEqual(len(list((state/"hooks").glob("*.json"))),1)


    def test_incomplete_cache_entry_is_reparsed(self):
        self.log(".codex/sessions/a.jsonl",self.codex())
        state=self.root/"state"
        agent.make_snapshot(self.root,state,NOW)
        path=state/"parse-cache.json"
        self.assertTrue(path.exists())
        data=json.loads(path.read_text())
        del next(iter(data["entries"].values()))["session"]
        path.write_text(json.dumps(data))
        self.assertEqual(len(agent.make_snapshot(self.root,state,NOW)["sessions"]),1)

    def test_cache_bounds_discovery_and_prunes_removed_files(self):
        for number in range(260):
            self.log(f".codex/sessions/{number}.jsonl",self.codex(str(number)))
            self.log(f".claude/projects/project/{number}.jsonl",[{"type":"user","sessionId":str(number),"timestamp":STAMP}])
        state=self.root/"state"
        self.assertEqual(len(agent.make_snapshot(self.root,state,NOW)["sessions"]),512)
        path=state/"parse-cache.json"
        self.assertTrue(path.exists())
        self.assertLess(path.stat().st_size,1024*1024)
        self.assertEqual(len(json.loads(path.read_text())["entries"]),512)
        for folder in (self.root/".codex/sessions",self.root/".claude/projects/project"):
            for transcript in folder.glob("*.jsonl"):
                transcript.unlink()
        self.assertEqual(agent.make_snapshot(self.root,state,NOW)["sessions"],[])
        self.assertEqual(json.loads(path.read_text())["entries"],{})


    def test_unrelated_cli_hooks_preserve_transcript_input_wait_across_snapshots(self):
        rows=self.codex()+[{"type":"response_item","timestamp":STAMP,"payload":{"type":"function_call","name":"request_user_input","call_id":"input-1"}}]
        self.log(".codex/sessions/a.jsonl",rows)
        state=self.root/"state"
        self.assertEqual(agent.make_snapshot(self.root,state,NOW)["sessions"][0]["state"],"needsAttention")
        args=[sys.executable,str(Path(agent.__file__).resolve()),"--home",str(self.root),"--state-dir",str(state)]
        for name in ("PreToolUse","PostToolUse"):
            event={"session_id":"a","hook_event_name":name,"tool_name":"Bash","tool_use_id":"parallel-1"}
            observed=subprocess.run(args+["hook","--provider","codex"],input=json.dumps(event),capture_output=True,text=True,check=True,timeout=10)
            self.assertEqual(observed.stdout.strip(),"{}")
            run=subprocess.run(args+["snapshot","--json"],capture_output=True,text=True,check=True,timeout=10)
            session=json.loads(run.stdout)["sessions"][0]
            self.assertEqual(session["state"],"needsAttention")
            self.assertEqual(set(session),{"id","provider","title","project","state","updatedAt","activity","parentId","isHelper"})
        for call_id in ("input-1","parallel-2"):
            event={"session_id":"a","hook_event_name":"PostToolUse","tool_name":"request_user_input" if call_id=="input-1" else "Bash","tool_use_id":call_id}
            subprocess.run(args+["hook","--provider","codex"],input=json.dumps(event),capture_output=True,text=True,check=True,timeout=10)
        run=subprocess.run(args+["snapshot","--json"],capture_output=True,text=True,check=True,timeout=10)
        self.assertEqual(json.loads(run.stdout)["sessions"][0]["state"],"working")

    def test_hook_application_preserves_pending_input_until_matching_completion(self):
        rows=self.codex()+[{"type":"response_item","timestamp":STAMP,"payload":{"type":"function_call","name":"request_user_input","call_id":"input-1"}}]
        pending=agent.read_codex(self.log("a.jsonl",rows),NOW)
        unrelated={"session_id":"a","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"parallel-1"}
        result=agent.apply_hook_state(pending,unrelated,NOW+timedelta(seconds=1))
        self.assertEqual(result["state"],"needsAttention")
        matching={"session_id":"a","hook_event_name":"PostToolUse","tool_name":"request_user_input","tool_use_id":"input-1"}
        self.assertEqual(agent.apply_hook_state(result,matching,NOW+timedelta(seconds=2))["state"],"working")

    def test_explicit_hook_turn_progression_resumes_transcript_input_wait(self):
        rows=self.codex()+[{"type":"response_item","timestamp":STAMP,"payload":{"type":"function_call","name":"request_user_input","call_id":"input-1"}}]
        self.log(".codex/sessions/a.jsonl",rows)
        state=self.root/"state"
        agent.make_snapshot(self.root,state,NOW)
        agent.ingest_hook("codex",{"session_id":"a","hook_event_name":"UserPromptSubmit"},self.root,state,NOW+timedelta(seconds=1))
        self.assertEqual(agent.make_snapshot(self.root,state,NOW+timedelta(seconds=2))["sessions"][0]["state"],"working")

    def test_bounded_tail_reasoning_does_not_clear_pending_input(self):
        for event in ("agent_reasoning","agent_message"):
            rows=self.codex(event="task_complete")+[
                {"type":"padding","payload":{"text":"x"*(agent.MAX_LOG_BYTES+100)}},
                {"type":"response_item","timestamp":STAMP,"payload":{"type":"function_call","name":"request_user_input","call_id":"input-1"}},
                {"type":"event_msg","timestamp":STAMP,"payload":{"type":event,"text":"private body"}}]
            result=agent.read_codex(self.log("large.jsonl",rows),NOW)
            self.assertEqual(result["state"],"needsAttention")
            self.assertNotIn("private body",json.dumps(result))

if __name__ == "__main__": unittest.main()
