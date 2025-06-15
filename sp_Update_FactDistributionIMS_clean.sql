USE [HALK]
GO
/****** Object:  StoredProcedure [HH].[Update_FactDistributionIMS]    Script Date: 6/15/2025 9:35:13 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE [HH].[Update_FactDistributionIMS]
@OL_ID bigint,
@DateID int
AS 
BEGIN

SET NOCOUNT ON


-- Example execution
-- exec [HH].[Update_FactDistributionIMS] 1002000414, 20231222

DECLARE @OL_orig bigint,
@Lag int

SET @OL_Orig = @OL_ID -- Save input value for later update in control table
SET @Lag = 90  -- History depth for recalculation

-- Step 1: Determine period boundaries
DECLARE @startDate int, @endDate int

SET @endDate = @DateID
SET @startDate = convert(varchar, dateadd(dd, -@Lag, convert(date, convert(varchar,@DateID))), 112);

DECLARE @status int
DECLARE @ChanelID int
-- Check 1: Duplicate outlet IDs
SELECT @OL_ID = isnull(HH.Outlets.OL_PID, @OL_ID) FROM HH.Outlets WHERE HH.Outlets.OL_ID = @OL_ID

-- Get outlet's channel and status
SELECT @ChanelID = Chanel_ID_Out, @status = [status] FROM HH.Outlets WHERE HH.Outlets.OL_ID = @OL_ID


-- Step 2: Delete outlet and its duplicates for selected date
DELETE 
	FROM HH.Fact_DistributionIMS
WHERE 
	OL_ID in (SELECT OL_ID FROM HH.Outlets WHERE (OL_PID = @OL_ID or OL_ID = @OL_ID))
	AND (DateID = @endDate)

-- If outlet is inactive, skip update
IF @status = 9 RETURN
			

-- Step 3: Get warehouse for outlet
DECLARE @Wh_id int

SELECT top 1 @Wh_id = isnull(a.WhID, 0)  
FROM HH.Outlets b INNER JOIN HH.TOCustomers a ON a.Cust_id = b.Cust_Id 
WHERE b.OL_ID = @OL_ID
-- Skip known excluded warehouse IDs
IF @Wh_id in (10, 28, 84, 28,29,30,31,32,33,34,35,37,38,42,43,44,36,39,41,46,47,50,45,52,40,51,48,49,85,90,94,95,98,100) RETURN

--print @OL_ID
--print @Wh_id

-- Step 4: Fill MSL plan
MERGE INTO HH.Fact_DistributionIMS AS f USING (
	SELECT @OL_ID AS OL_ID, @DateID AS DateID, PrID FROM  HH.getOutletMSL(@OL_ID, @DateID)) AS m
ON f.PrID = m.PrId and f.OL_ID = @OL_ID and f.DateID = @DateID
WHEN MATCHED THEN
	UPDATE SET isMSL = 1
WHEN NOT MATCHED THEN
	INSERT (OL_ID, DateID, ChanelID, PrID, WhID, GroupID, isMSL)
	VALUES (@OL_ID, @DateID, @ChanelID, m.PrId, @Wh_id, 0, 1);

-- Step 5: Fill Matrix plan
MERGE INTO HH.Fact_DistributionIMS AS f USING (
	SELECT @OL_ID AS OL_ID, @DateID AS DateID, PrID FROM  HH.getOutletMatrix(@OL_ID, @DateID)) AS m
ON f.PrID = m.PrId and f.OL_ID = @OL_ID and f.DateID = @DateID
WHEN MATCHED THEN
	UPDATE SET isMatrix = 1
WHEN NOT MATCHED THEN 
	INSERT (OL_ID, DateID, ChanelID, PrID, WhID, GroupID, isMSL, isMatrix)
	VALUES (@OL_ID, @DateID, @ChanelID, m.PrId, @Wh_id, 0, NULL,1); 
			
-- Step 6: Determine parent-child outlets and fetch IMS sales
DECLARE @RC int
SELECT top 1 @RC = RC FROM HH.Get_TT (@OL_ID) --WHERE OL_ID = @OL_ID

--print @RC

Declare @SKUInMatrix int
select @SKUInMatrix = count(PrID) from [HH].[getOutletMatrix] (@OL_ID, @DateID)
	
IF @RC = 1
BEGIN 
-- Proceed only if matrix exists (14/05/2018)
IF @SKUInMatrix > 0
	BEGIN
		MERGE INTO HH.Fact_DistributionIMS AS f USING  (
			SELECT @OL_Id AS OL_ID, @DateID as DateID, PrID
			FROM HH.Fact_IMSSales
			WHERE 
				OL_ID in (SELECT OL_ID FROM HH.Get_TT (@OL_ID)) 
				AND (DateID >= @startDate AND DateID <= @endDate) 
				-- Sometimes product was shipped before being registered
				AND  PrID IN		(

	-- Exclude replacements not in matrix (14/06/2018)
				Select PrID From [HH].[getListProduct]  (@OL_Id, @DateId, @ChanelID)		
					)
			AND Product_Qty > 0
			GROUP BY PrID
		) AS m
		ON f.PrID = m.PrID AND f.OL_ID = @OL_Id AND f.DateID = @DateId AND f.isMatrix = 1  
		WHEN MATCHED THEN
		UPDATE SET isIMS = 1
		WHEN NOT MATCHED THEN
 			INSERT (OL_ID, DateID, ChanelID, PrID, WhID, GroupID, isIMS)
			VALUES (@OL_ID, @DateID, @ChanelID, m.PrId, @Wh_id, 0, 1);
	END
END

IF @RC = 0
BEGIN 
	MERGE INTO HH.Fact_DistributionIMS AS f USING  (
		SELECT 
			@OL_Id AS OL_ID, @DateId AS DateID, PrID 
		FROM 
			HH.Fact_IMSSales
		WHERE 
			OL_ID in (SELECT OL_ID FROM HH.Get_TT (@OL_ID)) 
			AND (DateID >= @startDate AND DateID <= @endDate)
			-- Sometimes product was shipped before being registered  
			AND PrID IS NOT Null 
			AND Product_Qty > 0
		GROUP BY PrID
	)  AS m
	ON f.PrID = m.PrID AND f.OL_ID = @OL_Id AND f.DateID = @DateId
	WHEN MATCHED THEN
	UPDATE SET isIMS = 1
	WHEN NOT MATCHED THEN 
 		INSERT (OL_ID, DateID, ChanelID, PrID, WhID, GroupID, isIMS)
		VALUES (@OL_ID, @DateID, @ChanelID, m.PrId, @Wh_id, 0, 1);
END

--Действие 8:обновляем группу замен GroupId
UPDATE HH.Fact_DistributionIMS
    SET GroupID = o.GroupID
FROM HH.Fact_DistributionIMS a INNER JOIN (
    SELECT 
		b.GroupID, r.PrID
    FROM 
	-----	clause 
		--	m.[MSLPlan] = 1
	-----	added on 20191030, it filters unused groups  
		(select b.GroupID, b.GroupMember from HH.MSLGroupReplacement b INNER JOIN [HH].[MSLReplacement] m on b.[GroupID] = m.[GroupID]	where m.[ChanelID] = @ChanelID and m.[MSLPlan] = 1) b
    CROSS apply 
		(SELECT Int_value AS PrID FROM dbo.fn_SplitString(b.GroupMember, ';')) r) o 
ON  o.PrID = a.PrID AND a.OL_ID = @OL_ID AND a.DateID = @DateID


-- Step 8: Update calculated MSL field

UPDATE HH.Fact_DistributionIMS
	SET MSLCalc = 1 
FROM	(SELECT 
		ROW_NUMBER() OVER(PARTITION BY a.DateID, OL_ID, GroupID ORDER BY isIMS DESC) AS fact,
		ChanelID, GroupID, a.DateID, OL_ID, PrID
		FROM HH.Fact_DistributionIMS a 
		INNER JOIN dbo.Date d ON d.DateID = a.DateID
		WHERE a.OL_ID = @OL_ID AND a.DateID = @DateID and isIMS > 0 and GroupID > 0) as fc -- Define actual IMS fact
	INNER JOIN 
		(SELECT 
		ROW_NUMBER() OVER(PARTITION BY a.DateID, OL_ID, GroupID ORDER BY isIMS DESC) AS [plan],
		ChanelID, GroupID, a.DateID, OL_ID, PrID
		FROM HH.Fact_DistributionIMS a 
		INNER JOIN dbo.Date d ON d.DateID = a.DateID
		WHERE a.OL_ID = @OL_ID AND a.DateID = @DateID and isMSL > 0 and GroupID > 0) as pl -- Define planned MSL
	ON fc.fact = pl.[plan] and  fc.ChanelID = pl.ChanelID and fc.GroupID=pl.GroupID and fc.DateID=pl.DateID and fc.OL_ID = pl.OL_ID 
	INNER JOIN	HH.Fact_DistributionIMS as fin
	ON Fin.PRID = pl.PRID and  Fin.DateID=pl.DateID and Fin.OL_ID = pl.OL_ID 

   
UPDATE HH.Fact_DistributionIMS
	SET MSLCalc = 1 
WHERE GroupID = 0 AND isIMS = 1 AND isMSL = 1 AND OL_ID = @OL_ID AND DateID = @DateID

-- Step 9: Update status in control table
 UPDATE manage.Fact_DistributionIMS
 SET Status = 1 WHERE OL_ID = @OL_orig AND DateID = @DateID
 
 -- Step 10: Update outlet/product technical table for OLAP refresh
 BEGIN
	MERGE INTO HH.Determenation AS f USING  (
		SELECT @OL_Id AS OL_ID)
		AS m
		ON f.Content = m.OL_ID
	WHEN NOT MATCHED THEN
		INSERT (Name,Content)
		VALUES ('Outlets', @OL_ID);
 END
-- Update product entries for OLAP refresh
 BEGIN
	MERGE INTO HH.Determenation AS f USING  
	(
		SELECT PrID
		FROM HH.Fact_DistributionIMS
		WHERE OL_ID = @OL_ID 
		AND DateID = @DateID 
	 ) AS m
		ON f.Content = m.PrID
	WHEN NOT MATCHED THEN
		INSERT (Name,Content)
		VALUES ('Product', PrID);
 END
END


