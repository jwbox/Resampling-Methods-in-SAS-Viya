/* a step by step walkthrough of the bootstrap action in the resample actionset
  link to wiki:
*/

/* setup a session - in SAS Studio use interactive mode for this walkthrough */
cas mysess sessopts=(caslib='casuser');
libname mylib cas sessref=mysess;

/* load actionSet */
proc cas;
	builtins.actionSetFromTable / table={caslib="Public" name="resampleActionSet.sashdat"} name="resample";
quit;

/* load example data to work with - three possible scenarios
		if rows are cases and no column identifies cases then: cases=NO and multipleRows=NO
		if rows are cases and unique_case is a column holding identifier then: cases=YES and multipleRows=NO
		if multiple rows per cases then need a column, unique_case, to hold identifier: cases=YES and multipleRows=YES
*/
proc casutil;
		load data=sashelp.cars casout="sample" replace; /* n=428 */
run;
proc cas;
		cases='NO';
		multipleRows='NO';
		if cases='YES' then do;
			resample.addRowID / intable='sample';
			datastep.runcode / code='data sample; set sample; unique_case=10000+rowID; drop rowID; run;'; /* n=428 */
			if multipleRows='YES' then do;
				datastep.runcode / code='data sample; set sample; do rep = 1 to 3; output; end; run;'; /* n=1284 */
			end;
		end;
		simple.numRows result=r / table='sample';
			print(r.numRows);
		table.fetch / table='sample' index=false to=12;
run;

/* define parameters to hold the action inputs */
proc cas;
	  intable='sample';
		B=100; /* desired number of resamples, used to reset value of bss to achieve at least B resamples */
		seed=12345; /* seed for call streaminit(seed) in the sampling */
		Bpct=1; /* The percentage of the original samples rowsize to use as the resamples size 1=100% */
		case='unique_case'; /* if the value is a column in intable then uses unique values of that column as cases, otherwise will use rows of intable as cases */
run;

		/* workflow: if case is a column in intable then do first route, otherwise do second route (else) */
		table.columninfo result=i / table=intable;
				/* if a column caseID is present then drop it - protected term, may be leftover from previous run */
				if i.columninfo.where(upcase(Column)='CASEID').nrows=1 then do;
					alterTable / name=intable columns={{name='caseID', drop=TRUE}};
				end;
				/* first route: case is a column in intable */
				if i.columninfo.where(upcase(column)=upcase(CASE)).nrows=1 then do;
						/* make a one column table of unique cases */
						fedsql.execDirect / query='create table '|| intable ||'_cases {options replace=TRUE} as select distinct '|| CASE ||' from '|| intable;
						/* addRowID to the unique cases, then rename rowID to caseID */
						resample.addRowID / intable=intable||'_cases';
							alterTable / name=intable||'_cases' columns={{name='rowID',rename='caseID'}};
						/* store the row count from the cases for further calculations */
						simple.numRows result=r / table=intable||'_cases';
						/* merge the caseID into the intable */
						fedsql.execDirect / query='create table '|| intable ||' {options replace=TRUE} as
																					select * From
																						(select * from '|| intable ||'_cases) a
																						left outer join
																						(select * from '|| intable ||') b
																						using('|| CASE ||')';
						/* drop the table of unique cases: size is in r.numrows, values are merged into intable */
						dropTable name=intable||'_cases';
				end;
				/* second route: case is not a column in intable */
				else do;
						/* addRowID to intable since rows are unique cases, then rename rowID to caseID */
						resample.addRowID / intable=intable;
							alterTable / name=intable columns={{name='rowID',rename='caseID'}};
						/* store the row count from the cases for further calculations */
						simple.numRows result=r / table=intable;
				end;
run;

		/* store the size of the original sample data (cases) in r.numCases */
		r.numCases=r.numrows;
		/* set r.Bpctn to the fraction of the original sample tables case size to be resampled for for each bootstrap resample */
		r.Bpctn=CEIL(r.numCases*Bpct);
		/* If user specifies desired number of resamples B then reset bss to achieve atleast B resamples */
		datastep.runcode result=t / code='data tempholdb; nthreads=_nthreads_; output; run;';
				fedsql.execDirect result=q / query='select max(nthreads) as M from tempholdb';
				dropTable name='tempholdb';
				bss=ceil(B/q[1,1].M);
run;

		/* create a structure for the bootstrap sampling.
					Will make resamples equal to the size of the original tables cases
					these instructions are sent to each _threadid_ and replicated bss times */
		datastep.runcode result=t / code='data '|| intable ||'_bskey;
									call streaminit('|| seed ||');
									do bs = 1 to '|| bss ||';
										bsID = (_threadid_-1)*'|| bss ||' + bs;
										do bs_caseID = 1 to '|| r.Bpctn ||';
											caseID = int(1+'|| r.numCases ||'*rand(''Uniform''));
											bag=1;
											output;
										end;
									end;
									drop bs;
								 run;';

		/*  take a look at how the table is distributed in the CAS environment */
		datastep.runcode result=t / code='data '||intable||'_bskey; set '||intable||'_bskey; host=_hostname_; threadid=_threadid_; run;';
		simple.crossTab / table={name=intable||"_bskey" where="bag=1"} row="bsid" col="host" aggregator="N";
		simple.crossTab / table={name=intable||"_bskey" where="bag=1"} row="bsid" col="threadid" aggregator="N";
run;

		/* use some fancy sql to merge the bootstrap structure with the sample data
					and include the rows not resampled with bag=0
					(see walkthrough of this SQL at the bottom of this file)*/
		fedSql.execDirect / query='create table '|| intable ||'_bs {options replace=TRUE} as
										select * from
											(select b.bsID, b.caseID, c.bs_caseID, CASE when c.bag is null then 0 else c.bag END as bag from
												(select bsID, caseID from
													(select distinct bsID from '|| intable ||'_bskey) as a, (select distinct caseID from '|| intable ||') as a2) as b
												full join
												(select bsID, bs_caseID, caseID, bag from '|| intable ||'_bskey) c
												using (bsID, caseID)) d
											left join
											'|| intable ||'
											using (caseID)';
run;

		/*  take a look at how the table is distributed in the CAS environment */
		datastep.runcode result=t / code='data '||intable||'_bs; set '||intable||'_bs; host=_hostname_; threadid=_threadid_; run;';
		simple.crossTab / table={name=intable||"_bs" where="bag=1"} row="bsid" col="host" aggregator="N";
		simple.crossTab / table={name=intable||"_bs" where="bag=1"} row="bsid" col="threadid" aggregator="N";
run;

		/* drop the table holding the bootstrap resampling structure */
		dropTable name=intable||'_bskey';
run;

		/* rebalance the table by partitioning by bsID, this will ensure all the same values of bsID are on the same host but not necessarily the same _threadid_ */
		partition / casout={name=intable||'_bs', replace=TRUE} table={name=intable||'_bs', groupby={{name='bsID'}}};
run;

		/*  take a look at how the table is distributed in the CAS environment */
		datastep.runcode result=t / code='data '||intable||'_bs; set '||intable||'_bs; host=_hostname_; threadid=_threadid_; run;';
		simple.crossTab / table={name=intable||"_bs" where="bag=1"} row="bsid" col="host" aggregator="N";
		simple.crossTab / table={name=intable||"_bs" where="bag=1"} row="bsid" col="threadid" aggregator="N";
		alterTable / name=intable||"_bs" columns={{name='host', drop=TRUE},{name='threadid', drop=TRUE}};
run;

		/* allow the action to have a response value, in this case the value of bss stored in a variable named bss */
		*resp.bss=bss;
		*send_response(resp);
run;

quit;


*cas mysess clear;

/* create full bootstrap sampled file with bag (sampled) and oob (unsampled) rows
logic for sample_bs:
	input tables:
		sample: source, caseID identifies unique rows
		sample_bskey: bsID, bs_caseID identifies unique rows
			has caseID to connect the bs_caseID to the sampled caseID in cars
	Merge Flow:
		1: cartisian join of distinct sample_bskey.bsID with sample - keep bsID, caseID
			rows 3-4
		2: join (1) with sample_bskey.(bsID, bs_caseID, caseID, bag), use case to assign bag=0 to unmatched rows
			rows (1) + 5-7
		3: left join (2) to sample data on caseID to populate source table columns
			rows 1-2 + (2) + 8-10
1	select * from
2		(select b.bsID, b.caseID, c.bs_caseID, CASE when c.bag is null then 0 else c.bag END as bag from
3			(select bsID, caseID from
4				(select distinct bsID from sample_bskey) as a, (select distint caseID from sample) as a2) as b
5			full join
6			(select bsID, bs_caseID, caseID, bag from sample_bskey) c
7			using (bsID, caseID)) d
8		left join
9		sample
10		using (caseID)
*/
