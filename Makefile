all:
	./rebar get-deps
	./rebar compile
	./rebar escriptize

clean:
	./rebar clean



	# cp deps/procket/priv/procket .
	# cp deps/procket/priv/procket.so .
	# ./escriptize.escript procket procket.so
	# erl -pa ebin -noinput -eval "detest:ez(),init:stop()"
	# rm procket procket.so
