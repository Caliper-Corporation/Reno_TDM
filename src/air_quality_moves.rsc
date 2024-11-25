/*
Script to post-process model data to produce input data for MOVES Air Quality Tool
*/


Macro "CalcAQMovesInputs" (Args)
    Shared model_dir, scenario_path, scenario, scen_year

	model_dir = Args.[Base Folder]
	scenario_path = Args.[Scenario Folder]
	scen_year = Args.AQYear

// Macro to compute average speeds (VMT/VHT) by time periods
	RunMacro("Calculate Average Speeds")

//0. Dialog box to get inputs
	output_location = scenario_path + "\\outputs\\air_quality\\"
	year = scen_year
	
//1. setup input file name  
	hwyDBD = model_dir + "\\resource\\data\\gis\\streets\\MasterNetwork.dbd"
	rampfile = model_dir + "\\resource\\data\\air_quality\\fixed_data\\Rampinput.csv"
	rtpfile = model_dir + "\\resource\\data\\air_quality\\fixed_data\\Roadtypeinput.csv"
	styvmtfile = model_dir + "\\resource\\data\\air_quality\\fixed_data\\SourceTypeDayVMTinput.CSV"
	hourvmtfile = model_dir + "\\resource\\data\\air_quality\\HourVMTinput.CSV"
	weekendinput = model_dir + "\\resource\\data\\air_quality\\speedinput_weekend.bin"

	asn_file = scenario_path + "\\outputs\\assignment\\assignment_daily_iteration.bin"

	//Params
	sourcetypefile = model_dir + "\\resource\\data\\air_quality\\SourceTypepct.CSV"
	monthfactorfile = model_dir + "\\resource\\data\\air_quality\\Monthfac.CSV"
	weekendfactorfile = model_dir + "\\resource\\data\\air_quality\\Weekend.CSV"
	localfactorfile = model_dir + "\\resource\\data\\air_quality\\LocalVMT.CSV"
	TODfacfile = model_dir + "\\resource\\data\\air_quality\\TODfac.CSV"
	speedallfile = model_dir + "\\resource\\data\\air_quality\\speeddefault.csv"
	TODlist = {"AM", "MD", "PM", "NT"}
	stylist = {11,21,31,32,41,42,43,51,52,53,54,61,62}
	
//2. Setup map view
	RunMacro("G30 new map", hwyDBD, "False")
	{mvw_node, mvw_line} = GetDBLayers(hwyDBD)
	SetLayer(mvw_line)
	// Make sure folder exists before exporting
	tempout = output_location+"temp"
	if GetDirectoryInfo(tempout, "All") = null then CreateDirectory(tempout)


	vmt1 = CreateTable("VMT by Area Report", output_location+"Report_byarea.csv","CSV",
						{{"Area",     "string", 20, null, "No"},
						{"Total_VMT", "Real",   10,    2, "No"}
						})
						
//3. Adjust Local VMT
	asnvw = OpenTable("asnvw", "FFB", {asn_file, })
	jnvw= JoinViews("jnvw", mvw_line+".ID", asnvw+".ID",)
	localfac = OpenTable("localfac", "CSV", {localfactorfile,})
	adj_jnvw = JoinViews("adj_jnvw", jnvw+".Urban", localfac+".Urban", {{"L",}})
	adjloc_expr = "if AQClass<>7 and AQClass<>10 then LocalFac/(1-LocalFac)*Daily_Tot_VMT else 0"
	modloc_expr = "if AQClass=7 then Daily_Tot_VMT else 0"
	CreateExpression(adj_jnvw, "adjloc", adjloc_expr,)
	CreateExpression(adj_jnvw, "modloc", modloc_expr,)
	
	SelectByQuery("urban", "several", "Select * where jnvw.Urban = 1")
	SelectByQuery("rural", "several", "Select * where jnvw.Urban = 0")
	{urbanl, urbanadj} = GetDataVectors(adj_jnvw+"|urban", {"modloc", "adjloc"},NULL)
	{rurall, ruraladj} = GetDataVectors(adj_jnvw+"|rural", {"modloc", "adjloc"},NULL)
	
	urlocfac = VectorStatistic(urbanadj, "Sum",)/VectorStatistic(urbanl, "Sum",)
	rulocfac = VectorStatistic(ruraladj, "Sum",)/VectorStatistic(rurall, "Sum",)
	ulfac = r2s(urlocfac)
	rlfac = r2s(rulocfac)
	//ShowMessage("urban local adjfac="+ulfac+" and rural local adjfac="+rlfac)
	CloseView(adj_jnvw)
	CloseView(jnvw)
	CloseView(localfac)
	CloseView(asnvw)
	
	for i=0 to 1 do // loop for HA and model area
		HAid = i2s(i)
		if i=0 then HAstr = "County" else HAstr = "HA"
		asnvw = OpenTable("asnvw", "FFB", {asn_file, })
		jnvw= JoinViews("jnvw", mvw_line+".ID", asnvw+".ID",)
		CloseView(asnvw)
		
		//Eliminate centroid connectors and adjust local
		daily_expr = "if AQClass<>7 then Daily_Tot_VMT else if Urban=1 then Daily_Tot_VMT*"+ulfac+" else Daily_Tot_VMT*"+rlfac
		CreateExpression(jnvw, "adj_Daily_VMT", daily_expr,)
		for j=1 to 4 do
			tod = TODlist[j]
			expr ="if AQClass<>7 then "+tod+"_Tot_VMT else if Urban=1 then "+tod+"_Tot_VMT*"+ulfac+" else "+tod+"_Tot_VMT*"+rlfac
			CreateExpression(jnvw, "adj_"+tod+"_VMT", expr,)
			CreateExpression(jnvw, "adj_"+tod+"_VHT", "adj_"+tod+"_VMT/"+tod+"_Avg_Speed",)
		end
		CreateExpression(jnvw, "adj_Daily_VHT", "adj_AM_VHT+adj_MD_VHT+adj_PM_VHT+adj_NT_VHT",)
		SetView(jnvw)
		CreateExpression(jnvw, "IsRamp", "if AQClass =8 or AQClass =9 then 'Ramp' else 'NonRamp'",)
		SelectByQuery("AQ", "several", "Select * where HA>=" + HAid + " and Roadtype>0")
		ExportView(jnvw+"|AQ", "FFB", tempout+"\\Street_AQ.bin", 
					{mvw_line+".ID", mvw_line+".Length", mvw_line+".Urban", mvw_line+".Roadtype", jnvw+".IsRamp", jnvw+".adj_Daily_VMT", jnvw+".adj_Daily_VHT",
					jnvw+".adj_AM_VMT", jnvw+".adj_MD_VMT", jnvw+".adj_PM_VMT", jnvw+".adj_NT_VMT", 
					jnvw+".adj_AM_VHT", jnvw+".adj_MD_VHT", jnvw+".adj_PM_VHT", jnvw+".adj_NT_VHT", 
					jnvw+".AM_Avg_Speed",jnvw+".MD_Avg_Speed",jnvw+".PM_Avg_Speed",jnvw+".NT_Avg_Speed"
					},)
		jnvw_AQ = OpenTable("jnvw_AQ", "FFB", {tempout+"\\Street_AQ.bin",})
		CloseView(jnvw)
		
		//4. Ramp
		SetView(jnvw_AQ)
		ramp = OpenTable("ramp", "CSV", {rampfile, })
		rampjn = JoinViewsMulti("rampjn", {ramp+".roadTypeID", ramp+".Ramp"}, {jnvw_AQ+".Roadtype",jnvw_AQ+".IsRamp"}, {{"A",}}) 
		CreateExpression(rampjn, "Ur", "if roadTypeID =4 or roadTypeID =5 then '1' else '0'",)
		//ExportView(rampjn+"|", "CSV", output_location+"Rampjn_"+HAstr+".csv",,{{"CSV Header", "True"}})
		rampagg =  SelfAggregate("rampagg", rampjn+".Ur", {"Fields", {"adj_Daily_VHT", {{"Sum"}}}}) //Aggregate by Urban(0/1) but failed.
		//ExportView(rampagg+"|", "CSV", output_location+"Rampagg_"+HAstr+".csv",,{{"CSV Header", "True"}})
		rampout = JoinViews("rampout", rampjn+".Ur", rampagg+".GroupedBy(Ur)", {{"L",}})
		CreateExpression(rampout, "rampFraction", "adj_Daily_VHT/[Sum(adj_Daily_VHT)]",)
		SetView(rampout)
		SelectByQuery("ramp", "several", "Select * where (roadTypeID=2 or roadTypeID=4) and Ramp = 'Ramp'") //newadded
		ExportView(rampout+"|ramp", "CSV", output_location+"Ramp_"+HAstr+".csv", {"roadTypeID","rampFraction"}, {{"CSV Header", "True"}})
		CloseView(ramp)
		CloseView(rampjn)
		CloseView(rampagg)
		CloseView(rampout)
		
		//5. Roadtype
		SetView(jnvw_AQ)
		rtp = OpenTable("rtp", "CSV", {rtpfile, })
		rtptemp =  JoinViewsMulti("rtptemp", {"rtp.roadTypeID"}, {"jnvw_AQ.Roadtype"}, {{"A",}})
		rtpagg = SelfAggregate("rtpagg", rtptemp+".sourceTypeID", {"Fields", {"adj_Daily_VMT", {{"Sum"}}}})
		rtpout = JoinViews("rtpout", rtptemp+".sourceTypeID", rtpagg+".GroupedBy(sourceTypeID)", {{"L",}})
		CreateExpression(rtpout, "roadTypeVMTFraction", "adj_Daily_VMT/[Sum(adj_Daily_VMT)]",) 
		ExportView(rtpout+"|", "CSV", output_location+"RoadType_"+HAstr+".csv", {"sourceTypeID", "roadTypeID", "roadTypeVMTFraction"}, {{"CSV Header", "True"}})
		
		CloseView(rtptemp)
		CloseView(rtpagg)
		CloseView(rtpout)
		CloseView(rtp)
		
		//6. SourcetypeVMT output
		styvmt = OpenTable("styvmt", "CSV", {styvmtfile, }) 
		yearID = CreateExpression(styvmt, "yearID", year, {"Integer"})
	
		//6.1 compute october weekday VMT and allocate to each source type
		sourcetypefac = OpenTable("sourcetypefac", "CSV", {sourcetypefile, })
		jnvw1 = JoinViewsMulti("jnvw1", {styvmt+".sourceTypeID", styvmt+".yearID"}, {sourcetypefac+".sourceTypeID", sourcetypefac+".Year"}, {{"L",}})
		
		//6.2 convert october table to other months weekday
		monthfactor = OpenTable("monthfactor", "CSV", {monthfactorfile, })
		jnvw2 = JoinViews("jnvw2", jnvw1+".monthID", monthfactor+".Month",{{"L",}})
	
		//6.3 convert all months weekday table to weekend+weekday table
		weekendfactor = OpenTable("weekendfactor", "CSV", {weekendfactorfile, })
		jnvw3 = JoinViewsMulti("jnvw2", {jnvw2+".yearID", jnvw2+".dayID"}, {weekendfactor+".Year", weekendfactor+".Day"}, {{"L",}})
		
		//6.4 Calculate model total VMT and fill in value
		vec_TotVMT = GetDataVector(jnvw_AQ+"|", "adj_Daily_VMT",NULL)
		TotVMT = VectorStatistic(vec_TotVMT, "Sum",)
		Tot_vmt = CreateExpression(jnvw3, "Tot_vmt", RealToString(TotVMT), {{"Type", "Real"}}) 
		if HAid = "0" then do
			CreateExpression(jnvw3, "VMT", "styFactor*Month_Model*wkFactor*Tot_vmt",)
			end
		else do
			CreateExpression(jnvw3, "VMT", "styFactor*Month_HA*wkFactor*Tot_vmt",)
			end
		ExportView(jnvw3+"|", "CSV", output_location+"SourceTypeDayVMT_"+HAstr+".csv", {styvmt+".sourceTypeID", "yearID", "monthID", "dayID", "VMT"} , {{"CSV Header", "True"}})
		
		CloseView(jnvw3)
		CloseView(jnvw2)
		CloseView(jnvw1)
	
		//7. HourVMT
		hourvmt = OpenTable("hourvmt", "CSV", {hourvmtfile, })
		TODfac = OpenTable("TODfac", "CSV", {TODfacfile, })
		hourinput = JoinViews("hourinput", hourvmt+".hourID", TODfac+".hour", {{"L",}})
		
		SetView(jnvw_AQ)
		hourvmtjn = JoinViews("hourvmt", hourinput+".roadTypeID", jnvw_AQ+".Roadtype", {{"A",}})
		vmt_expr = "if TOD='NT' then adj_NT_VMT/11 else if TOD='AM' then adj_AM_VMT/3 else if TOD='MD' then adj_MD_VMT/7 else if TOD='PM' then adj_PM_VMT/3" 
		CreateExpression(hourvmtjn, "hourlyVMT", vmt_expr,)
		pct_expr = "if dayID = 5 then hourlyVMT/adj_Daily_VMT else hourVMTFraction" //weekend data should be left as is
		CreateExpression(hourvmtjn, "hourVMTFraction", pct_expr,)
		ExportView(hourvmtjn+"|", "CSV", output_location+"HourVMT_"+HAstr+".csv", {"sourceTypeID", "roadTypeID", "dayID", "hourID", "hourVMTFraction"}, {{"CSV Header", "True"}})
		
		CloseView(hourinput)
		CloseView(hourvmtjn)
		CloseView(hourvmt)
		
		//9.0 Report Summary
		AddRecord(vmt1,{
			{"Area",      HAstr},
			{"Total_VMT", TotVMT}
		})
		
		vmt2 = SelfAggregate("vmt2", jnvw_AQ+".Roadtype", {"Fields", {"adj_Daily_VMT", {{"Sum"}}}, {"AM_Avg_Speed", {{"Avg", Length}}} }) //Fields option is not working
		ExportView(vmt2+"|", "CSV", output_location+"Report_byRoadtype_"+HAstr+".csv", {"GroupedBy(Roadtype)", "Sum(adj_Daily_VMT)", "Avg(AM_Avg_Speed)", "Avg(MD_Avg_Speed)", "Avg(PM_Avg_Speed)","Avg(NT_Avg_Speed)"} , {{"CSV Header", "True"}})
		//ExportView(vmt2+"|", "CSV", output_location+"Report_byRoadtype_"+HAstr+".csv",  , {{"CSV Header", "True"}})
		
		CloseView(jnvw_AQ)
		
		//8. Speed output	
		//Read speed input and generate weekend data
		speedall = OpenTable("speedall", "CSV", {speedallfile, })//newadded
		SetView(speedall)
		CreateExpression(speedall, "dayID", "Right(i2s(hourDayID),1)",)
		SelectByQuery("wkend", "several", "Select * where dayID='2'") 
		ExportView(speedall+"|wkend", "FFB", weekendinput,{"sourceTypeID", "roadTypeID", "hourDayID", "avgSpeedBinID", "avgSpeedFraction"},)
		
		//loop through TOD
		for m=1 to 4 do
			TOD = TODlist[m]
			outputname = tempout+"\\"+TOD +"_Speed_"+HAstr+".bin"
			
			//convert to speedbin
			jnvw = OpenTable("jnvw", "FFB", {tempout+"\\Street_AQ.bin",})
			bin_expr = "if "+TOD+"_Avg_Speed<72.5 then Ceil(("+TOD+"_Avg_Speed+2.5)/5) else if "+TOD+"_Avg_Speed>=72.5 then 16"
			CreateExpression(jnvw, "speedbin", bin_expr, {"Integer"})
			CreateExpression(jnvw, "Tot_VHT", "adj_"+TOD+"_VHT",)
			ExportView(jnvw+"|", "FFB", tempout+"\\"+TOD+"_jnvw.bin", , )
			DestroyExpression(jnvw+".speedbin")
			DestroyExpression(jnvw+".Tot_VHT")
			CloseView(jnvw)
			
			tdjnvw = OpenTable("tdjnvw", "FFB", {tempout+"\\"+TOD+"_jnvw.bin",})
			
			spdfile = model_dir + "\\resource\\data\\air_quality\\fixed_data\\speedinput_"+TOD+".bin"
			spd = opentable("spd", "FFB", {spdfile, })
			spdjn =  JoinViewsMulti("spdjn", {"spd.roadTypeID", "spd.avgSpeedBinID"}, {tdjnvw+".Roadtype", tdjnvw+".speedbin"}, {{"A",}}) 

			//ExportView(spdjn+"|", "FFB", tempout+"\\"+TOD+"_spdjn.bin", {"sourceTypeID", "roadTypeID", "hourDayID", "avgSpeedBinID","Tot_VHT"}, )
			
			spdagg = SelfAggregate("tdjnvw", tdjnvw+".Roadtype", )
			
			spdout = JoinViews("spdout", spdjn+".roadTypeID", spdagg+".GroupedBy(Roadtype)",{{"L",}})
			CreateExpression(spdout, "SpeedFraction", "Tot_VHT/[Sum(adj_"+TOD+"_VHT)]",)
			CreateExpression(spdout, "avgSpeedFraction", "if SpeedFraction>0 then SpeedFraction else 0",) //fill in zero
			
			ExportView(spdout+"|", "FFB", outputname, {"sourceTypeID", "roadTypeID", "hourDayID", "avgSpeedBinID", "avgSpeedFraction"} , )

			CloseView(spdout)
			CloseView(spdagg)
			CloseView(spdjn)
			CloseView(spd)
			CloseView(tdjnvw)
		end
		//Combine all TOD and weekend table
		ConcatenateFiles({tempout+"\\AM_Speed_"+HAstr+".bin", tempout+"\\MD_Speed_"+HAstr+".bin", tempout+"\\PM_Speed_"+HAstr+".bin", tempout+"\\NT_Speed_"+HAstr+".bin", weekendinput}, tempout+"\\Speed_"+HAstr+".bin")
		CopyFile(tempout+"\\AM_Speed_"+HAstr+".dcb", tempout+"\\Speed_"+HAstr+".dcb")
		
		spdfinal = OpenTable("spdfinal", "FFB", {tempout+"\\Speed_"+HAstr+".bin",})
		ExportView(spdfinal+"|", "CSV", output_location+"Speed_"+HAstr+".csv", ,{{"CSV Header", "True"}})
		//10. Close all views
		vws = GetViewNames()
		for k = 4 to vws.length do
			CloseView(vws[k])
		end
	end
	CloseView(vmt1)
	PutInRecycleBin(tempout)
	RunMacro("Close All Maps and Views")	
	return(True)
endMacro

//update status and output location
Macro "Update Status AQ" (select_macro)
    Shared run_status, run_status_a
		HideItem("run_status")
		ShowItem("run_status_a")
EndMacro


// Macro to compute average speeds by time periods
Macro "Calculate Average Speeds"
	 Shared scenario_path

     // Time period
     periods = {"AM","MD","PM","NT"}

     // Build path to "resource\data" path from the user specified "scenarios" location
     path_info = ParseString(scenario_path, "\\")
     for i = 1 to (path_info.length-1) do
       counts_path_info = counts_path_info+path_info[i]+"\\"
     end

     // Open daily assignment file
     daily_file = scenario_path +"outputs\\assignment\\assignment_daily_iteration.bin"
     daily_vw   = OpenTable("asgn_view", "FFB", {daily_file},)

     //------------------------------------------------------------------------------------------
     // Step 1:  Compute Regional Speed by time period
     // Add Average Speed fields by period
     daily_fields_type = {{"AM_Avg_Speed", "Real", 10, 3},
                          {"MD_Avg_Speed", "Real", 10, 3},
                          {"PM_Avg_Speed", "Real", 10, 3},
                          {"NT_Avg_Speed", "Real", 10, 3}}
     RunMacro("TCB Add View Fields",{daily_vw,daily_fields_type})

     for t = 1 to periods.length do
        vmt = GetDataVector(daily_vw+"|", periods[t]+"_Tot_VMT",{{"Sort Order", {{"ID", "Ascending"}}}})
        vht = GetDataVector(daily_vw+"|", periods[t]+"_Tot_VHT",{{"Sort Order", {{"ID", "Ascending"}}}})
        avg_speed = vmt/vht

        SetDataVector(daily_vw+"|",periods[t]+"_Avg_Speed",avg_speed,{{"Sort Order", {{"ID", "Ascending"}}}})
     end // period

    // Close views
    CloseView(daily_vw)
EndMacro
