-module(detest).
-export([main/1,ez/0]).
-export([]).
-define(PATH,".detest").
-define(INF(F,Param),
	case butil:ds_val(quiet,cfg) of 
	true ->
		ok;
	_ ->
		io:format("~p ~p: ~s~n",[time(),?MODULE,io_lib:fwrite(F,Param)])
	end).
-define(INF(F),?INF(F,[])).

ez() ->
	Ebin = filelib:wildcard("ebin/*"),
	Deps = filelib:wildcard("deps/*/ebin/*"),
	Files = 
	[begin
		{ok,Bin} = file:read_file(Fn),
		{filename:basename(Fn),Bin}
	end || Fn <- Ebin++Deps], 
	%["procket","procket.so"]
	{ok,{_,Bin}} = zip:create("detest.ez",Files,[memory]),
	file:write_file("detest.ez",Bin).


main([]) ->
	io:format("Command: ./detest <options> yourscript.erl~n"++
		"Options:~n"
		"-h    print help~n"++
		"-v    print stdout from nodes~n"++
		"-q    quiet~n");
main(["-h"]) ->
	main([]);
main(Param) ->
	[ScriptNm|_] = lists:reverse(Param),
	ets:new(cfg, [named_table,public,set,{read_concurrency,true}]),
	case lists:member("-v",Param) of
		true ->
			butil:ds_add(verbose,true,cfg);
		_ ->
			ok
	end,
	case lists:member("-q",Param) of
		true ->
			butil:ds_add(quiet,true,cfg);
		_ ->
			ok
	end,
	[] = os:cmd(epmd_path() ++ " -daemon"),
	application:ensure_all_started(lager),

	case compile:file(ScriptNm,[binary,return_errors,{parse_transform, lager_transform}]) of
		{ok,Mod,Bin} ->
			code:load_binary(Mod, filename:basename(ScriptNm), Bin);
		Err ->
			Mod = undefined,
			?INF("Unable to compile: ~p",[Err]),
			halt(1)
	end,
	Cfg = apply(Mod,cfg,[]),
	GlobCfgs = proplists:get_value(global_cfg,Cfg,[]),
	NodeCfgs = proplists:get_value(per_node_cfg,Cfg,[]),
	Nodes = proplists:get_value(nodes,Cfg),
	Path = ?PATH,

	os:cmd("rm -rf "++Path),

	% case detest_net:start([{butil:ip_to_tuple(ndaddr(Nd)),
	% 						proplists:get_value(delay,Nd,{0,0}),
	% 						ndnm(Nd)} || Nd <- Nodes]) of
	% 	{error,NetPids} ->
	% 		DetestName = undefined,
	% 		?INF("Unable to setup interfaces. Run as sudo? Kill your vpn app?~nFailed:~p",[NetPids]),
	% 		halt(1);
	% 	{ok,NetPids,DetestName} ->
	% 		ok
	% end,
	NetPids = [],
	
	compile_cfgs(GlobCfgs++NodeCfgs),

	% create files in etc
	[begin
		filelib:ensure_dir([Path,"/",ndnm(Nd),"/etc"]),
		[begin
			FBin = render_cfg(G,[{nodes,[[{distname,distname(Nd)}|Nd] || Nd <- Nodes]}]),
			Nm = [Path,"/",ndnm(Nd),"/etc/",filename:basename(dtlnm(G))],
			filelib:ensure_dir(Nm),
			ok = file:write_file(Nm,FBin)
		end || G <- GlobCfgs]
	 end || Nd <- Nodes],

	[begin
		[begin
			FBin = render_cfg(NC,Nd),
			Nm = [Path,"/",ndnm(Nd),"/etc/",filename:basename(dtlnm(NC))],
			filelib:ensure_dir(Nm),
			ok = file:write_file(Nm,FBin)
		end || NC <- NodeCfgs]
	end || Nd <- Nodes],

	% setup_dist(),
	{ok, _} = net_kernel:start(['detest@127.0.0.1', longnames]),
	erlang:set_cookie(node(),'detest'),


	case catch apply(Mod,setup,[?PATH]) of
		{'EXIT',Err0} ->
			?INF("Setup failed ~p",[Err0]),
			halt(1);
		_ ->
			ok
	end,
	
	% spawn nodes
	RunPids = 
	[begin
		case proplists:get_value(cmd,Nd,"") of
			"" ->
				RunCmd = proplists:get_value(cmd,Cfg);
			RunCmd ->
				ok
		end,
		AppPth = lists:flatten([Path,"/",ndnm(Nd),"/etc/app.config"]),
		case filelib:is_regular(AppPth) of
			true ->
				AppCmd = " -config "++filename:absname(AppPth);
			false ->
				AppCmd = ""
		end,
		VmArgs = lists:flatten([Path,"/",ndnm(Nd),"/etc/vm.args"]),
		case filelib:is_regular(VmArgs) of
			true ->
				VmCmd = " -args_file "++filename:absname(VmArgs);
			false ->
				VmCmd = ""
		end,

		Ebins = string:join([filename:absname(Nm) || Nm <- ["ebin"|filelib:wildcard("deps/*/ebin")]]," "),
		Cmd = "erl -noshell -noinput -setcookie detest -name "++atom_to_list(distname(Nd))++
				" -pa "++Ebins++" "++AppCmd++VmCmd++" "++RunCmd,
		timer:sleep(300),
		run(Cmd)
	end || Nd <- Nodes],

	DistNames = [{proplists:get_value(name,Nd),distname(Nd)} || Nd <- Nodes],
	
	case connect(Nodes,os:timestamp()) of
		{error,Node} ->
			?INF("Unable to connect to ~p",[Node]);
		ok ->
			timer:sleep(500),
			case wait_app(Nodes,proplists:get_value(wait_for,Cfg),os:timestamp()) of
				{error,Node} ->
					?INF("Timeout waiting for app to start on ~p",[Node]);
				ok ->
					case catch apply(Mod,run,[DistNames,?PATH]) of
						{'EXIT',Err1} ->
							?INF("Test failed ~p",[Err1]);
						_ ->
							?INF("Test finished.")
					end
			end
	end,

	{StopMod,StopFunc,StopArg} = proplists:get_value(stop,Cfg,{init,stop,[]}),

	% [Pid ! stop || Pid <- RunPids],
	Pids = [spawn(fun() -> rpc:call(distname(Nd),StopMod,StopFunc,StopArg) end) || Nd <- Nodes],
	wait_pids(Pids),
	[butil:safesend(NetPid,stop) || NetPid <- NetPids],
	timer:sleep(200),
	% If nodes still alive, kill them forcefully
	[RP ! stop || RP <- RunPids],
	timer:sleep(200),
	wait_pids(NetPids),
	apply(Mod,cleanup,[?PATH]).

wait_app(_,undefined,_Started) ->
	ok;
wait_app([H|T],App,Started) ->
	case timer:now_diff(os:timestamp(),Started) > 30*1000000 of
		true ->
			{error,H};
		_ ->
			case rpc:call(distname(H),application,which_applications,[],1000) of
				[_|_] = L ->
					case lists:keymember(App,1,L) of
						true ->
							wait_app(T,App,Started);
						false ->
							wait_app([H|T],App,Started)
					end;
				_ ->
					wait_app([H|T],App,Started)
			end
	end;
wait_app([],_,_) ->
	ok.

run([_|_] = Cmd) ->
	?INF("Running ~p",[Cmd]),
	spawn(fun() ->
		Port = open_port({spawn,Cmd},[exit_status,use_stdio,binary,stream]),
		{os_pid,OsPid} = erlang:port_info(Port,os_pid),
		run(Port,OsPid)
	end).
run(Port,OsPid) ->
	receive
		{Port,{exit_status,_Status}} ->
			ok;
		{Port,{data,Bin}} ->
			case butil:ds_val(verbose,cfg) of
				true ->
					io:format("~s",[Bin]);
				_ ->
					ok
			end,
			run(Port,OsPid);
		stop ->
			os:cmd("kill "++integer_to_list(OsPid))
	end.

wait_pids([undefined|T]) ->
	wait_pids(T);
wait_pids([H|T]) ->
	case erlang:is_process_alive(H) of
		true ->
			timer:sleep(100),
			wait_pids([H|T]);
		false ->
			wait_pids(T)
	end;
wait_pids([]) ->
	ok.

connect([H|T],Start) ->
	case timer:now_diff(os:timestamp(),Start) > 10000000 of
		true ->
			{error,H};
		_ ->
			?INF("Connecting to ~p",[ndnm(H)]),
			Node = distname(H),
			case net_kernel:hidden_connect(Node) of
				true ->
					case net_adm:ping(Node) of
		        		pang ->
		        			timer:sleep(100),
							connect([H|T],Start);
						_ ->
							connect(T,os:timestamp())
					end;
				false ->
					timer:sleep(100),
					connect([H|T],Start)
			end
	end;
connect([],_) ->
	ok.

render_cfg(Cfg,P) ->
	case Cfg of
		{FN,Param} ->
			ok;
		FN ->
			Param = []
	end,
	case apply(modnm(FN),render,[[{basepath,?PATH}|P]++Param]) of
		{ok,Bin} ->
			Bin;
		Err ->
			?INF("Error rendering ~p~nParam:~p~nError:~p",[FN,P,Err]),
			halt(1)
	end.

modnm(FN) ->
	list_to_atom(filename:basename(FN)).

ndnm([{_,_}|_] = N) ->
	ndnm(proplists:get_value(name,N,""));
ndnm(N) ->
	NS = atom_to_list(N),
	[NS1|_] = string:tokens(NS,"@"),
	NS1.

distname([{_,_}|_] = N) ->
	distname(proplists:get_value(name,N,""));
distname(N) ->
	case os:type() of
		% {unix,linux} ->
		% 	N;
		{_,_} ->
			[Nm|_] = string:tokens(atom_to_list(N),"@"),
			list_to_atom(Nm++"@127.0.0.1")
	end.

% ndaddr([{_,_}|_] = N) ->
% 	ndaddr(proplists:get_value(name,N,""));
% ndaddr(N) ->
% 	NS = atom_to_list(N),
% 	[_,Addr] = string:tokens(NS,"@"),
% 	Addr.

dtlnm(G) ->
	case G of
		{GNm,_} ->
			GNm;
		GNm ->
			GNm
	end.

compile_cfgs(L) ->
	[begin
		case erlydtl:compile_file(dtlnm(Cfg), list_to_atom(filename:basename(dtlnm(Cfg))),[{out_dir,false},return]) of
			ok ->
				ok;
			{ok,_} ->
				ok;
			{ok,_,_} ->
				ok;
			Err ->
				?INF("Error compiling ~p~n~p",[dtlnm(Cfg),Err]),
				halt(1)
		end
	end || Cfg <- L].


epmd_path() ->
  ErtsBinDir = filename:dirname(element(2,file:get_cwd())),
  Name = "epmd",
  case os:find_executable(Name, ErtsBinDir) of
    false ->
      case os:find_executable(Name) of
        false ->
          ?INF("Could not find epmd.~n"),
          halt(1);
        GlobalEpmd ->
          GlobalEpmd
      end;
    Epmd ->
      Epmd
  end.