
USE [HALK]
GO

/**** Object:  StoredProcedure [HH].[Update_CalcIMS]    Script Date: 6/15/2025 ****/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author: Alla Osypova
-- Created: 2023-05-12
-- Description: Fixes stock snapshots and shipments for IMS calculation.
-- =============================================
CREATE PROCEDURE [HH].[Update_CalcIMS]
    @DateID INT  -- Snapshot date (always the first day of the month)
AS
BEGIN
    SET NOCOUNT ON;

    -- Example: EXEC HH.Update_CalcIMS 20180301

    -- =============================================
    -- Step 1: Snapshot current stock into HH.CalcIMS_Stock
    -- =============================================
    DELETE FROM HH.CalcIMS_Stock WHERE DateID = @DateID;

    INSERT INTO HH.CalcIMS_Stock
    SELECT 
        [Archive_ID],
        [DateID],
        [Cust_id],
        [WhID],
        [Product_id],
        [PrID],
        [Product_Qty],
        [Amount]
    FROM [HALK].[HH].[Fact_StockDistr]
    WHERE DateID = @DateID;

    -- =============================================
    -- Step 2: Insert shipments into HH.CalcIMS_NIS (if not already exists)
    -- =============================================
    INSERT INTO HH.CalcIMS_NIS ([DateID],[OrdNo],[WhID],[PrID],[Qty],[Amount])
    SELECT 
        a.DateID,
        a.OrdNo,
        a.WhID,
        b.PrID,
        b.Qty,
        b.Amount
    FROM JDE.Fact_Order a
    INNER JOIN JDE.Fact_OrderDetail b 
        ON a.DateID = b.DateID AND a.OrdNo = b.OrdNo 
    LEFT JOIN HH.CalcIMS_NIS c 
        ON a.OrdNo = c.OrdNo
    WHERE c.OrdNo IS NULL 
      AND a.DateID BETWEEN 20160101 AND @DateID;

    -- =============================================
    -- Step 3: Build temporary price table for IMS
    -- =============================================
    IF NOT EXISTS (
        SELECT * FROM sys.objects 
        WHERE object_id = OBJECT_ID('HH.PriceIMS') AND type = 'U'
    )
    BEGIN
        CREATE TABLE HH.PriceIMS (
            DistrID INT NULL,
            DateID INT NULL,
            Price MONEY NULL,
            PrID INT NULL
        );
    END
    ELSE
    BEGIN
        DELETE FROM HH.PriceIMS;
    END

    INSERT INTO HH.PriceIMS ([DateID], DistrID, Price, PrID)
    SELECT DISTINCT 
        ord.DateID AS [Date],
        wh.DistrID,
        det.Price,
        cod.PrID
    FROM JDE.Fact_OrderDetail det
    INNER JOIN JDE.Fact_Order ord ON det.OrdNo = ord.OrdNo 
    INNER JOIN JDE.ProdCodes cod ON det.SKU = cod.SKU 
    INNER JOIN dbo.Warehouses wh ON ord.WhID = wh.WhID
    WHERE wh.WhID IN (
            SELECT DISTINCT WhID 
            FROM HH.Fact_IMSSales
        )
      AND wh.WhID NOT IN (
            SELECT WhID 
            FROM HH.fnExcepDistrPrice()
        )
      AND det.Price > 0
      AND ord.DateID >= CONVERT(VARCHAR(8), DATEADD(MONTH, -6, GETDATE()), 112);

    -- =============================================
    -- Step 4: Calculate amounts for zero-priced shipments using fn_GetPrice
    -- =============================================
    UPDATE a
    SET a.Amount = HH.fn_GetPrice(b.DistrID, a.PrID, a.DateID) * a.Qty
    FROM HH.CalcIMS_NIS a
    INNER JOIN dbo.Warehouses b ON a.WhID = b.WhID
    WHERE a.DateID IS NOT NULL
      AND a.WhID IS NOT NULL
      AND a.PrID IS NOT NULL
      AND a.Amount = 0;

    -- =============================================
    -- Step 5: Drop temporary price table
    -- =============================================
    DROP TABLE HH.PriceIMS;

    -- =============================================
    -- Step 6: Adjust order dates based on transit corrections
    -- =============================================
    UPDATE a
    SET a.DateID = b.DateID
    FROM HH.CalcIMS_NIS a
    INNER JOIN HH.CalcIMS_NISTransit b 
        ON a.OrdNo = b.OrdNo AND a.DateID <> b.DateID;

END
