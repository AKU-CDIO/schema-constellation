USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Orders]    Script Date: 2026-08-04 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure : dbo.usp_Build_FCAP1A_Orders
    Version          : 0.1
    Author           : Rais.
    Development Date : 2026-08-04

    Purpose:
        Builds the FCAP 1A Orders dataset � order-level records
        (order, dictionary, classification, and procedure/medication attributes)
        restricted to the Extended FCAP cohort -> dbo.tbl_FCAP1A_Orders

    Notes:
        Execute this script as a single batch. Do not insert GO statements inside the procedure body.
*/

CREATE OR ALTER PROCEDURE [dbo].[usp_Build_FCAP1A_Orders]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunStart        DATETIME = SYSDATETIME();
    DECLARE @RunEnd          DATETIME;
    DECLARE @DurationSeconds INT;
    DECLARE @RecordCount     INT = 0;
    DECLARE @TotalEligible   INT = 0;

    DECLARE @WindowStart      DATE = '2022-11-05';
    DECLARE @WindowEnd        DATE = '2026-06-14';
    DECLARE @WindowEndNextDay DATE = DATEADD(DAY, 1, @WindowEnd);

    -- Source tables involved in this build (used to populate SourceTable column)
    DECLARE @SourceTableList NVARCHAR(500) =
        N'OmOrd_Main, OmOrd_Main2, OmOrd_Main3, OmOrdDict_Main, OmCat_Main, OmGrp_Main, MisCpt_Main, RegAcct_Main, HimRec_Main, tbl_FCAP1A_Cohort10_Extended';

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log_dropLater','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log_dropLater (
            LogID           INT IDENTITY(1,1) PRIMARY KEY,
            RunStart        DATETIME        NOT NULL,
            RunEnd          DATETIME        NULL,
            DurationSeconds INT             NULL,
            RunStatus       VARCHAR(20)     NOT NULL,
            DataTopic       NVARCHAR(100)   NOT NULL,
            WindowStart     DATE            NULL,
            WindowEnd       DATE            NULL,
            TotalEligible   INT             NULL,
            RecordCount     INT             NULL,
            ProcessedBy     NVARCHAR(100)   NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000)  NULL,
            Remarks         NVARCHAR(4000)  NULL
        );
    END;

    IF OBJECT_ID('dbo.tbl_FCAP1A_Orders','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Orders;

    CREATE TABLE dbo.tbl_FCAP1A_Orders (
        OrderRowID                            INT IDENTITY(1,1) NOT NULL PRIMARY KEY,

        SourceID                              NVARCHAR(50)      NULL,
        PatientID                             NVARCHAR(50)      NOT NULL,
        VisitID                               NVARCHAR(50)      NULL,
        EmrNumber                             NVARCHAR(255)     NULL,
        MultipleDepartmentMedicalRecordNumber NVARCHAR(255)     NULL,
        AccountNumber                         NVARCHAR(255)     NULL,
        Name                                  NVARCHAR(255)     NULL,
        Birthdate                             DATETIME          NULL,
        Age                                   NVARCHAR(50)      NULL,
        Sex                                   NVARCHAR(50)      NULL,
        SocialSecurityNumber                  NVARCHAR(50)      NULL,
        HealthCareNumber                      NVARCHAR(255)     NULL,
        RegistrationStatus                    NVARCHAR(255)     NULL,
        AdmitDateTime                         DATETIME          NULL,
        ServiceDateTime                       DATETIME          NULL,

        OrderID                               NVARCHAR(255)     NOT NULL,
        OrderNumber                           NVARCHAR(255)     NULL,
        OrderDateTime                         DATETIME          NULL,
        StartDateTime                         DATETIME          NULL,

        OrderDictionaryID                     NVARCHAR(255)     NULL,
        OrderName                             NVARCHAR(255)     NULL,

        OrderType                             NVARCHAR(255)     NULL,
        DictionaryType                        NVARCHAR(255)     NULL,
        CategoryName                          NVARCHAR(255)     NULL,
        CategoryType                          NVARCHAR(255)     NULL,
        GroupName                             NVARCHAR(255)     NULL,

        OrderStatus                           NVARCHAR(255)     NULL,
        CompletedOrder                        NVARCHAR(255)     NULL,
        IncompleteOrder                       NVARCHAR(255)     NULL,
        Priority                              NVARCHAR(255)     NULL,
        Quantity                              NVARCHAR(255)     NULL,
        CollectionDateTime                    DATETIME          NULL,

        AomMedicationType                     NVARCHAR(255)     NULL,
        AmbulatoryMedication                  NVARCHAR(50)      NULL,
        Generic                               NVARCHAR(255)     NULL,
        GenericMnemonic                       NVARCHAR(255)     NULL,
        GenericMedicationName                 NVARCHAR(255)     NULL,
        TradeMedicationName                   NVARCHAR(255)     NULL,
        NdcDinNumber                          NVARCHAR(255)     NULL,
        CompoundMedication                    NVARCHAR(255)     NULL,

        CptCode                               NVARCHAR(255)     NULL,
        CptDescription                        NVARCHAR(255)     NULL,

        OrderProvider                         NVARCHAR(255)     NULL,
        RequestProvider                       NVARCHAR(255)     NULL,
        OrderOrigin                           NVARCHAR(255)     NULL,
        OrderSource                           NVARCHAR(255)     NULL,
        RowUpdateDatetime                     DATETIME          NULL,

        ClassificationText                    NVARCHAR(1000)    NULL,
        OrderClass                            NVARCHAR(50)      NULL,

        SourceTable                           NVARCHAR(500)     NOT NULL,
        ExecutionOn                           DATETIME          NOT NULL
    );

    BEGIN TRY

        SELECT @TotalEligible = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        IF OBJECT_ID('tempdb..#Cohort') IS NOT NULL DROP TABLE #Cohort;

        SELECT DISTINCT
            PatientID
        INTO #Cohort
        FROM dbo.tbl_FCAP1A_Cohort10_Extended
        WHERE PatientID IS NOT NULL;
		

        IF OBJECT_ID('tempdb..#OrderDetails') IS NOT NULL DROP TABLE #OrderDetails;

        SELECT
            o.SourceID,
            ra.PatientID,
            o.VisitID,
            hm.EmrNumber,
            hm.MultipleDepartmentMedicalRecordNumber,
            ra.AccountNumber,
            CONCAT(hm.NameFirst, ' ', hm.NameMiddle, ' ', hm.NameLast) AS Name,
            hm.Birthdate,
            hm.Age,
            hm.Sex,
            hm.SocialSecurityNumber,
            hm.HealthCareNumber,
            ra.RegistrationStatus,
            ra.AdmitDateTime,
            ra.ServiceDateTime,

            o.OmOrdID AS OrderID,
            o.OrderNumber,
            o.OrderDateTime,
            o3.StartDateTime,

            o2.Procedure_OmOrdDictID AS OrderDictionaryID,
            COALESCE(
                NULLIF(o2.DictionaryOverrideMedicationName, ''),
                d.Name
            ) AS OrderName,

            o.OrderType,
            d.Type AS DictionaryType,
            c.Name AS CategoryName,
            c.Type AS CategoryType,
            g.Name AS GroupName,

            o3.Status AS OrderStatus,
            o3.CompletedOrder,
            o3.IncompleteOrder,
            o2.Priority,
            o2.Quantity,
            o2.CollectionDateTime,

            o.AomMedicationType,
            d.AmbulatoryMedication,
            d.Generic,
            d.GenericMnemonic,
            d.FsvGeneric AS GenericMedicationName,
            d.FsvTradeName AS TradeMedicationName,
            d.NdcDinNumber,
            o3.CompoundMedication,

            cpt.Mnemonic AS CptCode,
            cpt.Name AS CptDescription,

            o2.OrderProvider,
            o3.RequestProvider,
            o.OrderOrigin,
            o2.Source AS OrderSource,
            o.RowUpdateDatetime,
            UPPER(CONCAT(
                ' ', d.Type,
                ' ', c.Name,
                ' ', c.Type,
                ' ', g.Name,
                ' '
            )) AS ClassificationText
        INTO #OrderDetails
        FROM [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrd_Main AS o

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_Main AS ra
            ON ra.SourceID = o.SourceID
           AND ra.VisitID  = o.VisitID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].HimRec_Main AS hm
            ON ra.SourceID  = hm.SourceID
           AND ra.PatientID = hm.PatientID

        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrd_Main2 AS o2
            ON  o2.SourceID = o.SourceID
            AND o2.OmOrdID  = o.OmOrdID

        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrd_Main3 AS o3
            ON  o3.SourceID = o.SourceID
            AND o3.OmOrdID  = o.OmOrdID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrdDict_Main AS d
            ON  d.SourceID    = o2.SourceID
            AND d.OmOrdDictID = o2.Procedure_OmOrdDictID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmCat_Main AS c
            ON  c.SourceID = o.SourceID
            AND c.OmCatID  = COALESCE(
                                o.Category_OmCatID,
                                d.Category_OmCatID
                              )

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmGrp_Main AS g
            ON  g.SourceID = d.SourceID
            AND g.OmGrpID  = d.Group_OmGrpID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisCpt_Main AS cpt
            ON  cpt.SourceID = d.SourceID
            AND cpt.MisCptID = d.CptCode_MisCptID

        WHERE o.OrderDatetime >= @WindowStart
          AND o.OrderDatetime <  @WindowEndNextDay;

        IF OBJECT_ID('tempdb..#ClassifiedOrders') IS NOT NULL DROP TABLE #ClassifiedOrders;

        SELECT
            od.*,
            CASE
                WHEN NULLIF(
                        LTRIM(RTRIM(CONVERT(varchar(100), od.AomMedicationType))),
                        ''
                     ) IS NOT NULL
                  OR NULLIF(od.NdcDinNumber, '') IS NOT NULL
                  OR UPPER(CONVERT(varchar(20), od.AmbulatoryMedication))
                        IN ('Y', 'YES', '1', 'TRUE')
                  OR od.ClassificationText LIKE '%MEDICATION%'
                  OR od.ClassificationText LIKE '%PHARM%'
                  OR od.ClassificationText LIKE '%DRUG%'
                THEN 'Medication order'

                WHEN od.CptCode IS NOT NULL
                  OR od.ClassificationText LIKE '%PROCEDURE%'
                  OR od.ClassificationText LIKE '%SURG%'
                  OR od.ClassificationText LIKE '%OPERATION%'
                THEN 'Procedure order'

                ELSE 'Other medical order'
            END AS OrderClass
        INTO #ClassifiedOrders
        FROM #OrderDetails AS od;

        INSERT INTO dbo.tbl_FCAP1A_Orders (
            SourceID,
            PatientID,
            VisitID,
            EmrNumber,
            MultipleDepartmentMedicalRecordNumber,
            AccountNumber,
            Name,
            Birthdate,
            Age,
            Sex,
            SocialSecurityNumber,
            HealthCareNumber,
            RegistrationStatus,
            AdmitDateTime,
            ServiceDateTime,
            OrderID,
            OrderNumber,
            OrderDateTime,
            StartDateTime,
            OrderDictionaryID,
            OrderName,
            OrderType,
            DictionaryType,
            CategoryName,
            CategoryType,
            GroupName,
            OrderStatus,
            CompletedOrder,
            IncompleteOrder,
            Priority,
            Quantity,
            CollectionDateTime,
            AomMedicationType,
            AmbulatoryMedication,
            Generic,
            GenericMnemonic,
            GenericMedicationName,
            TradeMedicationName,
            NdcDinNumber,
            CompoundMedication,
            CptCode,
            CptDescription,
            OrderProvider,
            RequestProvider,
            OrderOrigin,
            OrderSource,
            RowUpdateDatetime,
            ClassificationText,
            OrderClass,
            SourceTable,
            ExecutionOn
        )
        SELECT
            c.SourceID,
            cohort.PatientID,
            c.VisitID,
            c.EmrNumber,
            c.MultipleDepartmentMedicalRecordNumber,
            c.AccountNumber,
            c.Name,
            c.Birthdate,
            c.Age,
            c.Sex,
            c.SocialSecurityNumber,
            c.HealthCareNumber,
            c.RegistrationStatus,
            c.AdmitDateTime,
            c.ServiceDateTime,
            c.OrderID,
            c.OrderNumber,
            c.OrderDateTime,
            c.StartDateTime,
            c.OrderDictionaryID,
            c.OrderName,
            c.OrderType,
            c.DictionaryType,
            c.CategoryName,
            c.CategoryType,
            c.GroupName,
            c.OrderStatus,
            c.CompletedOrder,
            c.IncompleteOrder,
            c.Priority,
            c.Quantity,
            c.CollectionDateTime,
            c.AomMedicationType,
            c.AmbulatoryMedication,
            c.Generic,
            c.GenericMnemonic,
            c.GenericMedicationName,
            c.TradeMedicationName,
            c.NdcDinNumber,
            c.CompoundMedication,
            c.CptCode,
            c.CptDescription,
            c.OrderProvider,
            c.RequestProvider,
            c.OrderOrigin,
            c.OrderSource,
            c.RowUpdateDatetime,
            c.ClassificationText,
            c.OrderClass,
            @SourceTableList AS SourceTable,
            @RunStart        AS ExecutionOn
        FROM #Cohort AS cohort
        INNER JOIN #ClassifiedOrders AS c
            ON cohort.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
             = c.PatientID     COLLATE SQL_Latin1_General_CP1_CI_AS;

        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_Orders;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log_dropLater (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            N'Orders',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            @RecordCount,
            SYSTEM_USER,
            NULL,
            N'Order events from OmOrd_Main, OmOrd_Main2, OmOrd_Main3 with dictionary/category/group enrichment and medication/procedure classification.'
        );

    END TRY
    BEGIN CATCH

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log_dropLater (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'FAILED',
            N'Orders',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            NULL,
            SYSTEM_USER,
            @Err,
            N'Error during Orders rebuild.'
        );

        THROW;
    END CATCH
END