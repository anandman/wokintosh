import importlib.util, json, tempfile, unittest
from pathlib import Path
from datetime import datetime, timezone, timedelta

spec=importlib.util.spec_from_file_location('agent_background',Path(__file__).parents[1]/'wokintosh_agent.py')
agent=importlib.util.module_from_spec(spec);spec.loader.exec_module(agent)
NOW=datetime(2026,11,24,18,0,tzinfo=timezone.utc)

def at(seconds=0):return agent.stamp(NOW+timedelta(seconds=seconds))

class BackgroundTests(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def log(self,rows,name='session.jsonl'):
        p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(''.join(json.dumps(r)+'\n' for r in rows));return p
    def claude(self,kind,seconds=0,**extra):return dict(type=kind,sessionId='session',timestamp=at(seconds),cwd='/src/example',**extra)
    def launch(self,task='job-1',seconds=0,tool='Bash'):
        return [self.claude('assistant',seconds,message={'content':[{'type':'tool_use','id':'call-'+task,'name':tool,'input':{'run_in_background':True,'description':'Background build','command':'PRIVATE COMMAND'}}]}),
                self.claude('user',seconds,toolUseResult={'backgroundTaskId':task},message={'content':[{'type':'tool_result','tool_use_id':'call-'+task,'content':'PRIVATE OUTPUT'}]})]
    def stop(self,seconds=2):return self.claude('system',seconds,subtype='turn_duration')
    def notification(self,task,status='completed',seconds=3,queued=False):
        value=f'<task-notification><task-id>{task}</task-id><status>{status}</status><summary>PRIVATE OUTPUT</summary></task-notification>'
        return dict(type='queue-operation',operation='enqueue',content=value,timestamp=at(seconds)) if queued else self.claude('user',seconds,isMeta=True,message={'content':value})
    def test_foreground_stop_does_not_finish_running_claude_shell(self):
        s=agent.read_claude(self.log(self.launch()+[self.stop()]),NOW+timedelta(seconds=2))
        self.assertEqual(s['state'],'working')
        self.assertEqual(s['background']['foregroundState'],'finished')
        self.assertEqual(s['background']['tasks'][0]['id'],'job-1')
        self.assertNotIn('PRIVATE',json.dumps(s))
    def test_all_jobs_must_finish_and_completion_time_is_stable(self):
        rows=self.launch()+self.launch('job-2',1)+[self.stop(),self.notification('job-1')]
        p=self.log(rows);self.assertEqual(agent.read_claude(p,NOW+timedelta(seconds=4))['state'],'working')
        rows.append(self.notification('job-2',seconds=5,queued=True));p=self.log(rows)
        s=agent.read_claude(p,NOW+timedelta(seconds=6))
        self.assertEqual(s['state'],'finished');self.assertEqual(s['updatedAt'],at(5))
        self.assertEqual(agent.read_claude(p,NOW+timedelta(seconds=100))['updatedAt'],at(5))
    def test_native_monitor_does_not_count_as_active_work(self):
        s=agent.read_claude(self.log(self.launch(tool='Monitor')+[self.stop()]),NOW+timedelta(seconds=2))
        self.assertEqual(s['state'],'idle');self.assertEqual(s['background']['tasks'][0]['kind'],'monitor')
    def test_claude_terminal_failure_and_cancellation_are_not_running(self):
        for status in ('failed','killed'):
            s=agent.read_claude(self.log(self.launch()+[self.stop(),self.notification('job-1',status)]),NOW+timedelta(seconds=4))
            self.assertEqual(s['state'],'finished')
            self.assertNotEqual(s['background']['tasks'][0]['status'],'running')
    def test_old_running_task_becomes_unknown_instead_of_done(self):
        s=agent.read_claude(self.log(self.launch()+[self.stop()]),NOW+timedelta(hours=2))
        self.assertEqual(s['state'],'unknown')
    def test_claude_stop_snapshot_survives_hook_summary_and_cache(self):
        event={'session_id':'session','hook_event_name':'Stop','background_tasks':[{'id':'task-1','type':'shell','status':'running','description':'Build','command':'PRIVATE'}]}
        agent.ingest_hook('claude',event,self.root,self.root/'state',NOW)
        for second in (0,1):
            s=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=second))['sessions'][0]
            self.assertEqual(s['state'],'working');self.assertEqual(s['background']['tasks'][0]['id'],'task-1');self.assertNotIn('PRIVATE',json.dumps(s))
        agent.ingest_hook('claude',dict(event,background_tasks=[]),self.root,self.root/'state',NOW+timedelta(seconds=3))
        s=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=4))['sessions'][0]
        self.assertEqual(s['state'],'finished');self.assertEqual(s['updatedAt'],at(3))
    def test_helper_registry_is_parent_scoped_and_does_not_create_parent_task_for_child(self):
        event={'session_id':'parent','agent_id':'child','hook_event_name':'SubagentStop','background_tasks':[{'id':'parent-job','type':'shell','status':'running'}]}
        agent.ingest_hook('claude',event,self.root,self.root/'state',NOW)
        s=agent.make_snapshot(self.root,self.root/'state',NOW)['sessions'][0]
        self.assertEqual(s['state'],'finished');self.assertFalse(s.get('background',{}).get('tasks'))
    def test_codex_command_item_remains_working_after_turn(self):
        rows=[{'type':'session_meta','timestamp':at(),'payload':{'id':'session','cwd':'/src/example'}},
              {'type':'event_msg','timestamp':at(1),'payload':{'type':'item_completed','item':{'type':'CommandExecution','id':'exec-1','process_id':'456','status':'in_progress','command':'PRIVATE'}}},
              {'type':'event_msg','timestamp':at(2),'payload':{'type':'task_complete'}}]
        p=self.log(rows);s=agent.read_codex(p,NOW+timedelta(seconds=2))
        self.assertEqual(s['state'],'working');self.assertEqual(s['background']['tasks'][0]['id'],'456');self.assertNotIn('PRIVATE',json.dumps(s))
        rows.append({'type':'event_msg','timestamp':at(3),'payload':{'type':'item_completed','item':{'type':'CommandExecution','id':'exec-1','process_id':'456','status':'completed','exit_code':0}}})
        s=agent.read_codex(self.log(rows),NOW+timedelta(seconds=4));self.assertEqual(s['state'],'finished');self.assertEqual(s['updatedAt'],at(3))
    def test_codex_native_exec_result_and_matching_write_exit(self):
        rows=[{'type':'session_meta','timestamp':at(),'payload':{'id':'session','cwd':'/src/example'}},
              {'type':'response_item','timestamp':at(1),'payload':{'type':'function_call','name':'exec_command','call_id':'c1','arguments':json.dumps({'cmd':'PRIVATE'})}},
              {'type':'response_item','timestamp':at(1),'payload':{'type':'function_call_output','call_id':'c1','output':'Process running with session ID 123\nOutput:\nPRIVATE'}},
              {'type':'event_msg','timestamp':at(2),'payload':{'type':'task_complete'}}]
        s=agent.read_codex(self.log(rows),NOW+timedelta(seconds=2));self.assertEqual(s['state'],'working')
        rows += [{'type':'response_item','timestamp':at(3),'payload':{'type':'function_call','name':'write_stdin','call_id':'c2','arguments':json.dumps({'session_id':123})}},
                 {'type':'response_item','timestamp':at(3),'payload':{'type':'function_call_output','call_id':'c2','output':'Process exited with code 0\nOutput:\nPRIVATE'}}]
        s=agent.read_codex(self.log(rows),NOW+timedelta(seconds=4));self.assertEqual(s['state'],'finished');self.assertNotIn('PRIVATE',json.dumps(s))
    def test_task_evidence_survives_bounded_scan_and_cache_reparse(self):
        name='.claude/projects/example/session.jsonl'
        rows=self.launch()+[self.stop()];p=self.log(rows,name)
        first=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=2))['sessions'][0]
        self.assertEqual(first['state'],'working')
        # Launch moves outside the bounded head/tail scan on the next parse.
        padding={'type':'padding','text':'x'*70000}
        rows=[self.claude('user')]+[padding]*10+self.launch()+[padding]*24+[self.stop(10)]
        self.log(rows,name)
        again=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=11))['sessions'][0]
        self.assertEqual(again['state'],'working');self.assertEqual(again['background']['tasks'][0]['id'],'job-1')
    def test_malformed_snapshot_cannot_clear_known_running_work(self):
        event={'session_id':'session','hook_event_name':'Stop','background_tasks':[{'id':'task-1','type':'shell','status':'running'}]}
        agent.ingest_hook('claude',event,self.root,self.root/'state',NOW)
        agent.ingest_hook('claude',dict(event,background_tasks=[{}]),self.root,self.root/'state',NOW+timedelta(seconds=1))
        s=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=2))['sessions'][0]
        self.assertEqual(s['state'],'working')
    def test_permission_wait_takes_precedence_over_jobs(self):
        event={'session_id':'session','hook_event_name':'Stop','background_tasks':[{'id':'job','type':'shell','status':'running'}]}
        agent.ingest_hook('claude',event,self.root,self.root/'state',NOW)
        agent.ingest_hook('claude',{'session_id':'session','hook_event_name':'PermissionRequest'},self.root,self.root/'state',NOW+timedelta(seconds=1))
        s=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=2))['sessions'][0]
        self.assertEqual(s['state'],'needsAttention')
    def test_task_identity_and_lifecycle_do_not_change_on_registry_refresh(self):
        event={'session_id':'session','hook_event_name':'Stop','background_tasks':[{'id':'job','type':'shell','status':'running'}]}
        agent.ingest_hook('claude',event,self.root,self.root/'state',NOW)
        agent.ingest_hook('claude',event,self.root,self.root/'state',NOW+timedelta(seconds=10))
        s=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=11))['sessions'][0]
        task=s['background']['tasks'][0]
        self.assertEqual(task['startedAt'],at());self.assertEqual(task['updatedAt'],at());self.assertEqual(task['observedAt'],at(10))
    def test_overflow_never_becomes_false_done(self):
        event={'session_id':'session','hook_event_name':'Stop','background_tasks':[{'id':'job-'+str(i),'type':'shell','status':'running'} for i in range(64)]}
        agent.ingest_hook('claude',event,self.root,self.root/'state',NOW)
        # A later transcript introduces more live work than fits in the inventory.
        rows=self.launch('extra')+[self.stop()]
        self.log(rows,'.claude/projects/example/session.jsonl')
        s=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=3))['sessions'][0]
        self.assertLessEqual(len(s['background']['tasks']),64)
        self.assertTrue(s['background'].get('incomplete'))
    def test_codex_completed_tool_without_exit_is_not_proof_process_ended(self):
        rows=[{'type':'session_meta','timestamp':at(),'payload':{'id':'session'}},
              {'type':'event_msg','timestamp':at(1),'payload':{'type':'item_completed','item':{'type':'CommandExecution','id':'exec','process_id':'321','status':'completed','exit_code':None}}},
              {'type':'event_msg','timestamp':at(2),'payload':{'type':'task_complete'}}]
        s=agent.read_codex(self.log(rows),NOW+timedelta(seconds=2));self.assertEqual(s['state'],'unknown')
    def test_positive_open_file_evidence_does_not_advance_task_lifecycle(self):
        import subprocess, sys, shutil
        if not (shutil.which('fuser') or shutil.which('lsof')):self.skipTest('No read-only open-file utility')
        output=self.root/'task.output';output.touch()
        process=subprocess.Popen([sys.executable,'-c','import sys,time; f=open(sys.argv[1],"a"); print("ready",flush=True); time.sleep(10)',str(output)],stdout=subprocess.PIPE,text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(),'ready')
            self.assertTrue(agent.background_file_is_open(output,0.8))
        finally:
            process.terminate();process.wait(timeout=2);process.stdout.close()
        self.assertFalse(agent.background_file_is_open(output,0.8))
    def test_reader_of_old_output_does_not_prove_background_job_is_alive(self):
        import subprocess, sys, shutil
        if not (shutil.which('fuser') or shutil.which('lsof')):self.skipTest('No open-file utility')
        output=self.root/'task.output';output.touch()
        process=subprocess.Popen([sys.executable,'-c','import sys,time; f=open(sys.argv[1],"r"); print("ready",flush=True); time.sleep(10)',str(output)],stdout=subprocess.PIPE,text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(),'ready')
            self.assertFalse(agent.background_file_is_open(output,0.8))
        finally:
            process.terminate();process.wait(timeout=2);process.stdout.close()
    def test_codex_parent_tracks_running_helper_even_when_helpers_are_hidden(self):
        parent=[{'type':'session_meta','timestamp':at(),'payload':{'id':'parent','cwd':'/src/example'}},{'type':'event_msg','timestamp':at(2),'payload':{'type':'task_complete'}}]
        child=[{'type':'session_meta','timestamp':at(1),'payload':{'id':'child','cwd':'/src/example','source':{'subagent':{'thread_spawn':{'parent_thread_id':'parent'}}}}},{'type':'event_msg','timestamp':at(1),'payload':{'type':'task_started'}}]
        self.log(parent,'.codex/sessions/parent.jsonl');self.log(child,'.codex/sessions/child.jsonl')
        snap=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=3));s=next(x for x in snap['sessions'] if x['id']=='parent')
        self.assertEqual(s['state'],'working');self.assertEqual(s['background']['tasks'][0]['kind'],'subagent')
        child.append({'type':'event_msg','timestamp':at(4),'payload':{'type':'task_complete'}})
        self.log(child,'.codex/sessions/child.jsonl')
        snap=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=5));s=next(x for x in snap['sessions'] if x['id']=='parent')
        self.assertEqual(s['state'],'finished');self.assertEqual(s['updatedAt'],at(4))
    def test_helper_wait_propagates_without_marking_parent_done(self):
        self.log([self.claude('user'),self.stop()],'.claude/projects/example/parent.jsonl')
        event={'session_id':'session','agent_id':'helper','hook_event_name':'PermissionRequest'}
        agent.ingest_hook('claude',event,self.root,self.root/'state',NOW+timedelta(seconds=3))
        snap=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=4))
        s=next(x for x in snap['sessions'] if x['id']=='session')
        self.assertEqual(s['state'],'needsAttention')
    def test_first_oversized_or_malformed_registry_never_reports_false_done(self):
        for tasks in ([{}],[{'id':'job-'+str(i),'type':'shell','status':'running'} for i in range(65)]):
            state=self.root/('state-'+str(len(tasks)))
            agent.ingest_hook('claude',{'session_id':'session','hook_event_name':'Stop','background_tasks':tasks},self.root,state,NOW)
            value=agent.make_snapshot(self.root,state,NOW)['sessions'][0]
            self.assertNotEqual(value['state'],'finished');self.assertTrue(value['background']['incomplete'])
    def test_terminal_history_eviction_does_not_make_session_permanently_unknown(self):
        rows=[]
        for i in range(70):rows += self.launch('job-'+str(i),i*2)+[self.notification('job-'+str(i),seconds=i*2+1)]
        rows.append(self.stop(150))
        value=agent.read_claude(self.log(rows),NOW+timedelta(seconds=151))
        self.assertEqual(value['state'],'finished');self.assertFalse(value['background'].get('incomplete',False))
    def test_explicit_launch_id_reuse_starts_new_incarnation_even_if_exit_was_missed(self):
        first=agent.read_claude(self.log(self.launch()+[self.stop()]),NOW+timedelta(seconds=3))
        rows=self.launch()+[self.stop()]+self.launch(seconds=20)+[self.stop(22)]
        value=agent.read_claude(self.log(rows),NOW+timedelta(seconds=23),previous_background=first['background'])
        self.assertEqual(value['background']['tasks'][0]['startedAt'],at(20))
    def test_live_finite_job_takes_precedence_over_stale_monitor(self):
        rows=self.launch('poller',tool='Monitor')+self.launch('build',seconds=1990)+[self.stop(1992)]
        value=agent.read_claude(self.log(rows),NOW+timedelta(seconds=2000))
        self.assertEqual(value['state'],'working')
    def test_duplicate_terminal_delivery_does_not_recreate_done_receipt(self):
        rows=self.launch()+[self.stop(),self.notification('job-1',seconds=3,queued=True)]
        first=agent.read_claude(self.log(rows),NOW+timedelta(seconds=4))
        rows.append(self.notification('job-1',seconds=10))
        again=agent.read_claude(self.log(rows),NOW+timedelta(seconds=11))
        self.assertEqual(first['updatedAt'],at(3));self.assertEqual(again['updatedAt'],first['updatedAt'])
    def test_hook_only_runner_gets_positive_liveness_after_merge(self):
        import os, shutil
        from unittest.mock import patch
        project=self.root.name+'-writer'
        output=Path(tempfile.gettempdir())/('claude-'+str(os.getuid()))/project/'tasks'/'job.output'
        output.parent.mkdir(parents=True,exist_ok=True);output.touch()
        try:
            self.log([self.claude('user'),self.stop()],'.claude/projects/'+project+'/session.jsonl')
            agent.ingest_hook('claude',{'session_id':'session','hook_event_name':'Stop','background_tasks':[{'id':'job','type':'shell','status':'running'}]},self.root,self.root/'state',NOW)
            with patch.object(agent,'background_file_is_open',return_value=True):
                value=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(hours=1))['sessions'][0]
            self.assertEqual(value['state'],'working');self.assertEqual(value['updatedAt'],at(2))
        finally:shutil.rmtree(output.parent.parent)
    def test_registry_disappearance_has_unspecified_end_not_success(self):
        event={'session_id':'session','hook_event_name':'Stop','background_tasks':[{'id':'job','type':'shell','status':'running'}]}
        agent.ingest_hook('claude',event,self.root,self.root/'state',NOW)
        agent.ingest_hook('claude',dict(event,background_tasks=[]),self.root,self.root/'state',NOW+timedelta(seconds=3))
        value=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=4))['sessions'][0]
        self.assertEqual(value['background']['tasks'][0]['status'],'ended')
    def test_malformed_text_part_does_not_drop_a_healthy_session(self):
        rows=[self.claude('user',message={'content':[{'type':'text','text':None}]}),self.stop()]
        self.log(rows,'.claude/projects/example/session.jsonl')
        value=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=3))
        self.assertEqual(len(value['sessions']),1)
    def test_authoritative_registry_clears_older_incomplete_cache(self):
        event={'session_id':'session','hook_event_name':'Stop','background_tasks':[{}]}
        agent.ingest_hook('claude',event,self.root,self.root/'state',NOW)
        self.log(self.launch()+[self.stop()],'.claude/projects/example/session.jsonl')
        agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=3))
        agent.ingest_hook('claude',dict(event,background_tasks=[]),self.root,self.root/'state',NOW+timedelta(seconds=4))
        value=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=5))['sessions'][0]
        self.assertEqual(value['state'],'finished');self.assertFalse(value['background']['incomplete'])
    def test_newer_legacy_hook_lifecycle_advances_background_foreground_time(self):
        self.log(self.launch()+[self.stop()],'.claude/projects/example/session.jsonl')
        agent.ingest_hook('claude',{'session_id':'session','hook_event_name':'Stop'},self.root,self.root/'state',NOW+timedelta(seconds=3))
        value=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=4))['sessions'][0]
        self.assertEqual(value['background']['foregroundUpdatedAt'],at(3));self.assertEqual(value['updatedAt'],at(3))
        # Retained metadata must not regress if an observer file is later absent.
        for hook in (self.root/'state/hooks').glob('*.json'):hook.unlink()
        value=agent.make_snapshot(self.root,self.root/'state',NOW+timedelta(seconds=5))['sessions'][0]
        self.assertEqual(value['background']['foregroundUpdatedAt'],at(3))
    def test_older_collectors_and_plain_foreground_sessions_unchanged(self):
        s=agent.read_claude(self.log([self.claude('user'),self.stop()]),NOW+timedelta(seconds=3))
        self.assertEqual(s['state'],'finished');self.assertNotIn('background',s)

if __name__=='__main__':unittest.main()
