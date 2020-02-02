/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (c)  1985-2020, University of Amsterdam
                              VU University Amsterdam
                              CWI, Amsterdam
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module('$autoload',
          [ '$find_library'/5,
            '$in_library'/3,
            '$define_predicate'/1,
            '$update_library_index'/0,
            '$autoload'/1,

            make_library_index/1,
            make_library_index/2,
            reload_library_index/0,
            autoload_path/1,

            autoload/1,                         % +File
            autoload/2                          % +File, +Imports
          ]).

:- meta_predicate
    '$autoload'(:),
    autoload(:),
    autoload(:, +).

:- dynamic
    library_index/3,                % Head x Module x Path
    autoload_directories/1,         % List
    index_checked_at/1.             % Time
:- volatile
    library_index/3,
    autoload_directories/1,
    index_checked_at/1.

user:file_search_path(autoload, library(.)).


%!  '$find_library'(+Module, +Name, +Arity, -LoadModule, -Library) is semidet.
%
%   Locate a predicate in the library. Name   and arity are the name
%   and arity of  the  predicate  searched   for.  `Module'  is  the
%   preferred target module. The return  values   are  the full path
%   name (excluding extension) of the library and module declared in
%   that file.

'$find_library'(Module, Name, Arity, LoadModule, Library) :-
    load_library_index(Name, Arity),
    functor(Head, Name, Arity),
    (   library_index(Head, Module, Library),
        LoadModule = Module
    ;   library_index(Head, LoadModule, Library)
    ),
    !.

%!  '$in_library'(+Name, +Arity, -Path) is semidet.
%!  '$in_library'(-Name, -Arity, -Path) is nondet.
%
%   Is true if Name/Arity is in the autoload libraries.

'$in_library'(Name, Arity, Path) :-
    atom(Name), integer(Arity),
    !,
    load_library_index(Name, Arity),
    functor(Head, Name, Arity),
    library_index(Head, _, Path).
'$in_library'(Name, Arity, Path) :-
    load_library_index(Name, Arity),
    library_index(Head, _, Path),
    functor(Head, Name, Arity).

%!  '$define_predicate'(:Head)
%
%   Make sure PredInd can be called. First  test if the predicate is
%   defined. If not, invoke the autoloader.

:- meta_predicate
    '$define_predicate'(:).

'$define_predicate'(Head) :-
    '$defined_predicate'(Head),
    !.
'$define_predicate'(Term) :-
    Term = Module:Head,
    (   compound(Head)
    ->  compound_name_arity(Head, Name, Arity)
    ;   Name = Head, Arity = 0
    ),
    '$undefined_procedure'(Module, Name, Arity, retry).


                /********************************
                *          UPDATE INDEX         *
                ********************************/

:- thread_local
    silent/0.

%!  '$update_library_index'
%
%   Called from make/0 to update the index   of the library for each
%   library directory that has a writable   index.  Note that in the
%   Windows  version  access_file/2  is  mostly   bogus.  We  assert
%   silent/0 to suppress error messages.

'$update_library_index' :-
    setof(Dir, writable_indexed_directory(Dir), Dirs),
    !,
    setup_call_cleanup(
        asserta(silent, Ref),
        guarded_make_library_index(Dirs),
        erase(Ref)),
    (   flag('$modified_index', true, false)
    ->  reload_library_index
    ;   true
    ).
'$update_library_index'.

guarded_make_library_index([]).
guarded_make_library_index([Dir|Dirs]) :-
    (   catch(make_library_index(Dir), E,
              print_message(error, E))
    ->  true
    ;   print_message(warning, goal_failed(make_library_index(Dir)))
    ),
    guarded_make_library_index(Dirs).

%!  writable_indexed_directory(-Dir) is nondet.
%
%   True when Dir is an indexed   library  directory with a writable
%   index, i.e., an index that can be updated.

writable_indexed_directory(Dir) :-
    index_file_name(IndexFile, [access([read,write])]),
    file_directory_name(IndexFile, Dir).
writable_indexed_directory(Dir) :-
    absolute_file_name(library('MKINDEX'),
                       [ file_type(prolog),
                         access(read),
                         solutions(all),
                         file_errors(fail)
                       ], MkIndexFile),
    file_directory_name(MkIndexFile, Dir),
    plfile_in_dir(Dir, 'INDEX', _, IndexFile),
    access_file(IndexFile, write).


                /********************************
                *           LOAD INDEX          *
                ********************************/

%!  reload_library_index
%
%   Reload the index on the next call

reload_library_index :-
    with_mutex('$autoload', clear_library_index).

clear_library_index :-
    retractall(library_index(_, _, _)),
    retractall(autoload_directories(_)),
    retractall(index_checked_at(_)).


%!  load_library_index(?Name, ?Arity) is det.
%
%   Try to find Name/Arity  in  the   library.  If  the predicate is
%   there, we are happy. If not, we  check whether the set of loaded
%   libraries has changed and if so we reload the index.

load_library_index(Name, Arity) :-
    atom(Name), integer(Arity),
    functor(Head, Name, Arity),
    library_index(Head, _, _),
    !.
load_library_index(_, _) :-
    notrace(with_mutex('$autoload', load_library_index_p)).

load_library_index_p :-
    index_checked_at(Time),
    get_time(Now),
    Now-Time < 60,
    !.
load_library_index_p :-
    findall(Index, index_file_name(Index, [access(read)]), List0),
    list_set(List0, List),
    retractall(index_checked_at(_)),
    get_time(Now),
    assert(index_checked_at(Now)),
    (   autoload_directories(List)
    ->  true
    ;   retractall(library_index(_, _, _)),
        retractall(autoload_directories(_)),
        read_index(List),
        assert(autoload_directories(List))
    ).

list_set([], R) :-                      % == list_to_set/2 from library(lists)
    closel(R).
list_set([H|T], R) :-
    memberchk(H, R),
    !,
    list_set(T, R).

closel([]) :- !.
closel([_|T]) :-
    closel(T).


%!  index_file_name(-IndexFile, +Options) is nondet.
%
%   True if IndexFile is an autoload   index file. Options is passed
%   to  absolute_file_name/3.  This  predicate   searches  the  path
%   =autoload=.
%
%   @see file_search_path/2.

index_file_name(IndexFile, Options) :-
    absolute_file_name(autoload('INDEX'),
                       IndexFile,
                       [ file_type(prolog),
                         solutions(all),
                         file_errors(fail)
                       | Options
                       ]).

read_index([]) :- !.
read_index([H|T]) :-
    !,
    read_index(H),
    read_index(T).
read_index(Index) :-
    print_message(silent, autoload(read_index(Dir))),
    file_directory_name(Index, Dir),
    setup_call_cleanup(
        '$push_input_context'(autoload_index),
        setup_call_cleanup(
            open(Index, read, In),
            read_index_from_stream(Dir, In),
            close(In)),
        '$pop_input_context').

read_index_from_stream(Dir, In) :-
    repeat,
        read(In, Term),
        assert_index(Term, Dir),
    !.

assert_index(end_of_file, _) :- !.
assert_index(index(Name, Arity, Module, File), Dir) :-
    !,
    functor(Head, Name, Arity),
    atomic_list_concat([Dir, '/', File], Path),
    assertz(library_index(Head, Module, Path)),
    fail.
assert_index(Term, Dir) :-
    print_message(error, illegal_autoload_index(Dir, Term)),
    fail.


                /********************************
                *       CREATE INDEX.pl         *
                ********************************/

%!  make_library_index(+Dir) is det.
%
%   Create an index for autoloading  from   the  directory  Dir. The
%   index  file  is  called  INDEX.pl.  In    Dir  contains  a  file
%   MKINDEX.pl, this file is loaded and we  assume that the index is
%   created by directives that appearin   this  file. Otherwise, all
%   source  files  are  scanned  for  their  module-header  and  all
%   exported predicates are added to the autoload index.
%
%   @see make_library_index/2

make_library_index(Dir0) :-
    forall(absolute_file_name(Dir0, Dir,
                              [ expand(true),
                                file_type(directory),
                                file_errors(fail),
                                solutions(all)
                              ]),
           make_library_index2(Dir)).

make_library_index2(Dir) :-
    plfile_in_dir(Dir, 'MKINDEX', _MkIndex, AbsMkIndex),
    access_file(AbsMkIndex, read),
    !,
    load_files(user:AbsMkIndex, [silent(true)]).
make_library_index2(Dir) :-
    findall(Pattern, source_file_pattern(Pattern), PatternList),
    make_library_index2(Dir, PatternList).

%!  make_library_index(+Dir, +Patterns:list(atom)) is det.
%
%   Create an autoload index INDEX.pl for  Dir by scanning all files
%   that match any of the file-patterns in Patterns. Typically, this
%   appears as a directive in MKINDEX.pl.  For example:
%
%   ```
%   :- prolog_load_context(directory, Dir),
%      make_library_index(Dir, ['*.pl']).
%   ```
%
%   @see make_library_index/1.

make_library_index(Dir0, Patterns) :-
    forall(absolute_file_name(Dir0, Dir,
                              [ expand(true),
                                file_type(directory),
                                file_errors(fail),
                                solutions(all)
                              ]),
           make_library_index2(Dir, Patterns)).

make_library_index2(Dir, Patterns) :-
    plfile_in_dir(Dir, 'INDEX', _Index, AbsIndex),
    ensure_slash(Dir, DirS),
    pattern_files(Patterns, DirS, Files),
    (   library_index_out_of_date(AbsIndex, Files)
    ->  do_make_library_index(AbsIndex, DirS, Files),
        flag('$modified_index', _, true)
    ;   true
    ).

ensure_slash(Dir, DirS) :-
    (   sub_atom(Dir, _, _, 0, /)
    ->  DirS = Dir
    ;   atom_concat(Dir, /, DirS)
    ).

source_file_pattern(Pattern) :-
    user:prolog_file_type(PlExt, prolog),
    PlExt \== qlf,
    atom_concat('*.', PlExt, Pattern).

plfile_in_dir(Dir, Base, PlBase, File) :-
    file_name_extension(Base, pl, PlBase),
    atomic_list_concat([Dir, '/', PlBase], File).

pattern_files([], _, []).
pattern_files([H|T], DirS, Files) :-
    atom_concat(DirS, H, P0),
    expand_file_name(P0, Files0),
    '$append'(Files0, Rest, Files),
    pattern_files(T, DirS, Rest).

library_index_out_of_date(Index, _Files) :-
    \+ exists_file(Index),
    !.
library_index_out_of_date(Index, Files) :-
    time_file(Index, IndexTime),
    (   time_file('.', DotTime),
        DotTime > IndexTime
    ;   '$member'(File, Files),
        time_file(File, FileTime),
        FileTime > IndexTime
    ),
    !.


do_make_library_index(Index, Dir, Files) :-
    ensure_slash(Dir, DirS),
    '$stage_file'(Index, StagedIndex),
    setup_call_catcher_cleanup(
        open(StagedIndex, write, Out),
        ( print_message(informational, make(library_index(Dir))),
          index_header(Out),
          index_files(Files, DirS, Out)
        ),
        Catcher,
        install_index(Out, Catcher, StagedIndex, Index)).

install_index(Out, Catcher, StagedIndex, Index) :-
    catch(close(Out), Error, true),
    (   silent
    ->  OnError = silent
    ;   OnError = error
    ),
    (   var(Error)
    ->  TheCatcher = Catcher
    ;   TheCatcher = exception(Error)
    ),
    '$install_staged_file'(TheCatcher, StagedIndex, Index, OnError).

%!  index_files(+Files, +Directory, +Out:stream) is det.
%
%   Write index for Files in Directory to the stream Out.

index_files([], _, _).
index_files([File|Files], DirS, Fd) :-
    catch(setup_call_cleanup(
              open(File, read, In),
              read(In, Term),
              close(In)),
          E, print_message(warning, E)),
    (   Term = (:- module(Module, Public)),
        is_list(Public)
    ->  atom_concat(DirS, Local, File),
        file_name_extension(Base, _, Local),
        forall(public_predicate(Public, Name/Arity),
               format(Fd, 'index((~k), ~k, ~k, ~k).~n',
                      [Name, Arity, Module, Base]))
    ;   true
    ),
    index_files(Files, DirS, Fd).

public_predicate(Public, PI) :-
    '$member'(PI0, Public),
    canonical_pi(PI0, PI).

canonical_pi(Var, _) :-
    var(Var), !, fail.
canonical_pi(Name/Arity, Name/Arity).
canonical_pi(Name//A0,   Name/Arity) :-
    Arity is A0 + 2.


index_header(Fd):-
    format(Fd, '/*  Creator: make/0~n~n', []),
    format(Fd, '    Purpose: Provide index for autoload~n', []),
    format(Fd, '*/~n~n', []).


                 /*******************************
                 *            EXTENDING         *
                 *******************************/

%!  autoload_path(+Path) is det.
%
%   Add Path to the libraries that are  used by the autoloader. This
%   extends the search  path  =autoload=   and  reloads  the library
%   index.  For example:
%
%     ==
%     :- autoload_path(library(http)).
%     ==
%
%   If this call appears as a directive,  it is term-expanded into a
%   clause  for  user:file_search_path/2  and  a  directive  calling
%   reload_library_index/0. This keeps source information and allows
%   for removing this directive.

autoload_path(Alias) :-
    (   user:file_search_path(autoload, Alias)
    ->  true
    ;   assertz(user:file_search_path(autoload, Alias)),
        reload_library_index
    ).

system:term_expansion((:- autoload_path(Alias)),
                      [ user:file_search_path(autoload, Alias),
                        (:- reload_library_index)
                      ]).


		 /*******************************
		 *      RUNTIME AUTOLOADER	*
		 *******************************/

%!  $autoload'(:PI) is semidet.
%
%   Provide PI by autoloading.  This checks:
%
%     - Explicit autoload/2 declarations
%     - Explicit autoload/1 declarations
%     - The library if current_prolog_flag(autoload, true) holds.

'$autoload'(PI) :-
    source_location(File, _Line),
    !,
    setup_call_cleanup(
        '$start_aux'(File, Context),
        '$autoload2'(PI),
        '$end_aux'(File, Context)).
'$autoload'(PI) :-
    '$autoload2'(PI).

'$autoload2'(PI) :-
    autoload_from(PI, LoadModule, FullFile),
    do_autoload(FullFile, PI, LoadModule).

%!  autoload_from(+PI, -LoadModule, -File) is semidet.
%
%   True when PI can be defined  by   loading  File which is defined the
%   module LoadModule.

autoload_from(Module:PI, LoadModule, FullFile) :-
    \+ current_prolog_flag(autoload, false),
    PI = Name/Arity,
    functor(Head, Name, Arity),
    '$get_predicate_attribute'(Module:Head, autoload, 1),
    !,
    current_autoload(Module:File, Ctx, import(Imports)),
    memberchk(PI, Imports),
    library_info(File, Ctx, FullFile, LoadModule, Exports),
    (   pi_in_exports(PI, Exports)
    ->  do_autoload(FullFile, Module:PI, LoadModule)
    ;   autoload_error(Ctx, not_exported(PI, File, FullFile, Exports)),
        fail
    ).
autoload_from(Module:Name/Arity, LoadModule, FullFile) :-
    \+ current_prolog_flag(autoload, false),
    PI = Name/Arity,
    current_autoload(Module:File, Ctx, all),
    library_info(File, Ctx, FullFile, LoadModule, Exports),
    pi_in_exports(PI, Exports).
autoload_from(Module:Name/Arity, LoadModule, Library) :-
    current_prolog_flag(autoload, true),
    '$find_library'(Module, Name, Arity, LoadModule, Library).

%!  do_autoload(+File, :PI, +LoadModule) is det.
%
%   Load File, importing PI into the qualified  module. File is known to
%   define LoadModule.
%
%   @tbd: Why do we need LoadModule?

do_autoload(Library, Module:Name/Arity, LoadModule) :-
    functor(Head, Name, Arity),
    '$update_autoload_level'([autoload(true)], Old),
    (   current_prolog_flag(verbose_autoload, true)
    ->  Level = informational
    ;   Level = silent
    ),
    print_message(Level, autoload(Module:Name/Arity, Library)),
    '$compilation_mode'(OldComp, database),
    (   Module == LoadModule
    ->  ensure_loaded(Module:Library)
    ;   (   '$get_predicate_attribute'(LoadModule:Head, defined, 1),
            \+ '$loading'(Library)
        ->  Module:import(LoadModule:Name/Arity)
        ;   use_module(Module:Library, [Name/Arity])
        )
    ),
    '$set_compilation_mode'(OldComp),
    '$set_autoload_level'(Old),
    '$c_current_predicate'(_, Module:Head).

%!  autoloadable(:Head, -File) is nondet.
%
%   True when Head can be  autoloaded   from  File.  This implements the
%   predicate_property/2 property autoload(File).  The   module  muse be
%   instantiated.

:- public                               % used from predicate_property/2
    autoloadable/2.

autoloadable(M:Head, FullFile) :-
    atom(M),
    current_module(M),
    \+ current_prolog_flag(autoload, false),
    (   callable(Head)
    ->  goal_name_arity(Head, Name, Arity),
        autoload_from(M:Name/Arity, _, FullFile)
    ;   findall((M:H)-F, autoloadable_2(M:H, F), Pairs),
        (   '$member'(M:Head-FullFile, Pairs)
        ;   current_autoload(M:File, Ctx, all),
            library_info(File, Ctx, FullFile, _, Exports),
            '$member'(PI, Exports),
            '$pi_head'(PI, Head),
            \+ memberchk(M:Head-_, Pairs)
        )
    ).
autoloadable(_:Head, FullFile) :-
    current_prolog_flag(autoload, true),
    (   callable(Head)
    ->  goal_name_arity(Head, Name, Arity),
        (   '$find_library'(_, Name, Arity, _, FullFile)
        ->  true
        )
    ;   '$in_library'(Name, Arity, autoload),
        functor(Head, Name, Arity)
    ).


autoloadable_2(M:Head, FullFile) :-
    current_autoload(M:File, Ctx, import(Imports)),
    library_info(File, Ctx, FullFile, _LoadModule, _Exports),
    '$member'(PI, Imports),
    '$pi_head'(PI, Head).

goal_name_arity(Head, Name, Arity) :-
    compound(Head),
    !,
    compound_name_arity(Head, Name, Arity).
goal_name_arity(Head, Head, 0).

%!  library_info(+Spec, +AutoloadContext, -FullFile, -Module, -Exports)
%
%   Find information about a library.

library_info(Spec, _, FullFile, Module, Exports) :-
    '$resolved_source_path'(Spec, FullFile, []),
    !,
    (   \+ '$loading_file'(FullFile, _Queue, _LoadThread)
    ->  '$current_module'(Module, FullFile),
        '$module_property'(Module, exports(Exports))
    ;   library_info_from_file(FullFile, Module, Exports)
    ).
library_info(Spec, Context, FullFile, Module, Exports) :-
    (   Context = (Path:_Line)
    ->  Extra = [relative_to(Path)]
    ;   Extra = []
    ),
    (   absolute_file_name(Spec, FullFile,
                           [ file_type(prolog),
                             access(read),
                             file_errors(fail)
                           | Extra
                           ])
    ->  '$register_resolved_source_path'(Spec, FullFile),
        library_info_from_file(FullFile, Module, Exports)
    ;   autoload_error(Context, no_file(Spec)),
        fail
    ).


library_info_from_file(FullFile, Module, Exports) :-
    setup_call_cleanup(
        '$open_source'(FullFile, In, State, [], []),
        '$term_in_file'(In, _Read, _RLayout, Term, _TLayout, _Stream,
                        [FullFile], []),
        '$close_source'(State, true)),
    (   Term = (:- module(Module, Exports))
    ->  !
    ;   nonvar(Term),
        skip_header(Term)
    ->  fail
    ;   throw(error(domain_error(module_file, FullFile), _))
    ).

skip_header(begin_of_file).


:- dynamic printed/3.
:- volatile printed/3.

autoload_error(Context, Error) :-
    suppress(Context, Error),
    !.
autoload_error(Context, Error) :-
    get_time(Now),
    assertz(printed(Context, Error, Now)),
    print_message(warning, error(autoload(Error), autoload(Context))).

suppress(Context, Error) :-
    printed(Context, Error, Printed),
    get_time(Now),
    (   Now - Printed < 1
    ->  true
    ;   retractall(printed(Context, Error, _)),
        fail
    ).

		 /*******************************
		 *          AUTOLOAD/2		*
		 *******************************/

autoload(File) :-
    current_prolog_flag(autoload, false),
    !,
    use_module(File).
autoload(M:File) :-

    '$must_be'(filespec, File),
    source_context(Context),
    retractall(M:'$autoload'(File, _, _)),
    assert_autoload(M:'$autoload'(File, Context, all)).

autoload(File, Imports) :-
    current_prolog_flag(autoload, false),
    !,
    use_module(File, Imports).
autoload(M:File, Imports0) :-
    '$must_be'(filespec, File),
    valid_imports(Imports0, Imports),
    source_context(Context),
    register_autoloads(Imports, M, File, Context),
    (   current_autoload(M:File, _, import(Imports))
    ->  true
    ;   assert_autoload(M:'$autoload'(File, Context, import(Imports)))
    ).

source_context(Path:Line) :-
    source_location(Path, Line),
    !.
source_context(-).

assert_autoload(Clause) :-
    '$initialization_context'(Source, Ctx),
    '$store_admin_clause'(Clause, _Layout, Source, Ctx).

valid_imports(Imports0, Imports) :-
    '$must_be'(list, Imports0),
    valid_import_list(Imports0, Imports).

valid_import_list([], []).
valid_import_list([H0|T0], [H|T]) :-
    '$pi_head'(H0, Head),
    '$pi_head'(H, Head),
    valid_import_list(T0, T).

%!  register_autoloads(+ListOfPI, +Module, +File, +Context)
%
%   Put an `autoload` flag on all   predicates declared using autoload/2
%   to prevent duplicates or the user defining the same predicate.

register_autoloads([], _, _, _).
register_autoloads([PI|T], Module, File, Context) :-
    PI = Name/Arity,
    functor(Head, Name, Arity),
    (   '$get_predicate_attribute'(Module:Head, autoload, 1)
    ->  (   current_autoload(Module:_File0, _Ctx0, import(Imports)),
            memberchk(PI, Imports)
        ->  '$permission_error'(redefine, imported_procedure, PI),
            fail
        ;   Done = true
        )
    ;   '$get_predicate_attribute'(Module:Head, imported, From)
    ->  (   '$resolved_source_path'(File, FullFile),
            module_property(From, file(FullFile))
        ->  Done = true
        ;   true
        )
    ;   true
    ),
    (   Done == true
    ->  true
    ;   '$set_predicate_attribute'(Module:Head, autoload, 1)
    ),
    register_autoloads(T, Module, File, Context).

pi_in_exports(PI, Exports) :-
    '$member'(E, Exports),
    canonical_pi(E, PI),
    !.

current_autoload(M:File, Context, Term) :-
    '$get_predicate_attribute'(M:'$autoload'(_,_,_), defined, 1),
    M:'$autoload'(File, Context, Term).
