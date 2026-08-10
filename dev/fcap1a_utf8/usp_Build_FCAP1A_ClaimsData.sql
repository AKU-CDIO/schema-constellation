USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_ClaimsData]    Script Date: 8/5/2026 1:00:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure : dbo.usp_Build_FCAP1A_ClaimsData
    Version          : 0.2
    Author           : Derick Imbati
    Development Date : 2026-08-05

    Purpose:
        Builds the FCAP 1A Claims dataset - claim-level records for each
        cohort patient account, carrying the full identity key set and
        patient demographics (as per the Orders SP) -> dbo.tbl_FCAP1A_ClaimsData

    Description:
        Claim-level records for each cohort patient account, including
        claim identifiers, dates, insurer, facility, business unit,
        version totals, bill totals and line transaction summaries.

    Keys carried (as per Orders SP):
        SourceID, PatientID, VisitID, EmrNumber,
        MultipleDepartmentMedicalRecordNumber, AccountNumber,
        Name, Birthdate, Age, Sex, SocialSecurityNumber, HealthCareNumber,
        RegistrationStatus, AdmitDateTime, ServiceDateTime

    Sources (per Information_Schema / AKULiveATdb):
        RegAcct_Main               -- patient -> account (visit) mapping
        HimRec_Main                -- patient demographics
        BarAcctClaim_Main          -- claim main record
        BarAcctClaim_Versions      -- claim version totals
        BarAcctClaim_LineFlds      -- claim line detail (line count)
        BarAcctClaim_LineTxns      -- claim line transactions (charges)
        BarAcctBill_Main           -- bill totals per account
        BarClaimFormat_Main        -- claim format lookup
        MisIns_Main                -- insurer lookup
        MisFac_Main                -- facility lookup
        MisBusUnit_Main            -- business unit lookup
        MisFinClass_Main           -- financial class lookup

    Notes:
        - RegAcct_Main.VisitID is used as the account OID that
          BarAcctClaim_Main.BarAccountOid_RegAcctID references.
        - Only the latest claim record and latest claim version per
          claim are kept (ROW_NUMBER rn = 1).
        - Line aggregates are scoped to the latest claim version.

    Window:
        2022-11-05 through 2026-06-14 inclusive
*/

CREATE OR ALTER PROCEDURE [dbo].[usp_Build_FCAP1A_ClaimsData]
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
        N'RegAcct_Main, HimRec_Main, BarAcctClaim_Main, BarAcctClaim_Versions, BarAcctClaim_LineFlds, BarAcctClaim_LineTxns, BarAcctBill_Main, BarClaimFormat_Main, MisIns_Main, MisFac_Main, MisBusUnit_Main, MisFinClass_Main, tbl_FCAP1A_Cohort10_Extended';

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log
        (
            LogID            INT IDENTITY(1,1) PRIMARY KEY,
            RunStart         DATETIME NOT NULL,
            RunEnd           DATETIME NULL,
            DurationSeconds  INT NULL,
            RunStatus        VARCHAR(20) NOT NULL,
            DataTopic        NVARCHAR(100) NOT NULL,
            WindowStart      DATE NULL,
            WindowEnd        DATE NULL,
            TotalEligible    INT NULL,
            RecordCount      INT NULL,
            ProcessedBy      NVARCHAR(100) NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage     NVARCHAR(4000) NULL,
            Remarks          NVARCHAR(4000) NULL
        );
    END;

    IF OBJECT_ID('dbo.tbl_FCAP1A_ClaimsData','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_ClaimsData;

    CREATE TABLE dbo.tbl_FCAP1A_ClaimsData
    (
        ClaimRowID               BIGINT IDENTITY(1,1) PRIMARY KEY,

        SourceID                 NVARCHAR(50)      NULL,
        PatientID                NVARCHAR(50)      NOT NULL,
        VisitID                  NVARCHAR(50)      NULL,
        EmrNumber                NVARCHAR(255)     NULL,
        MultipleDepartmentMedicalRecordNumber NVARCHAR(255) NULL,
        AccountNumber            NVARCHAR(255)     NULL,
        Name                     NVARCHAR(255)     NULL,
        Birthdate                DATETIME          NULL,
        Age                      NVARCHAR(50)      NULL,
        Sex                      NVARCHAR(50)      NULL,
        SocialSecurityNumber     NVARCHAR(50)      NULL,
        HealthCareNumber         NVARCHAR(255)     NULL,
        RegistrationStatus       NVARCHAR(255)     NULL,
        AdmitDateTime            DATETIME          NULL,
        ServiceDateTime          DATETIME          NULL,

        ClaimID                  NVARCHAR(250)     NULL,
        ClaimDate                DATETIME          NULL,
        DetailFromDate           DATETIME          NULL,
        DetailThroughDate        DATETIME          NULL,
        BillNumber               NVARCHAR(30)      NULL,

        ClaimFormatID            NVARCHAR(25)      NULL,
        ClaimFormatName          NVARCHAR(45)      NULL,

        ClaimInsuranceID         NVARCHAR(25)      NULL,
        ClaimInsuranceName       NVARCHAR(45)      NULL,
        FinancialClassName       NVARCHAR(45)      NULL,

        FacilityID               NVARCHAR(20)      NULL,
        FacilityName             NVARCHAR(45)      NULL,
        BusUnitID                NVARCHAR(15)      NULL,
        BusUnitName              NVARCHAR(45)      NULL,

        VersionID                INT               NULL,
        VersionType              NVARCHAR(30)      NULL,
        ClaimTotalCharges        MONEY             NULL,
        TotalCoveredAncillary    MONEY             NULL,
        TotalNonCoveredAncillary MONEY             NULL,
        TotalCoveredRoom         MONEY             NULL,
        TotalNonCoveredRoom      MONEY             NULL,

        BillTotalCharges         MONEY             NULL,
        BillCount                INT               NULL,
        LineCount                INT               NULL,
        LineTransactionCount     INT               NULL,
        LineTransactionTotal     MONEY             NULL,

        FirstTransactionDate     DATETIME          NULL,
        LastTransactionDate      DATETIME          NULL,
        RowUpdateDateTime        DATETIME          NULL,

        SourceTable              NVARCHAR(500)     NOT NULL,
        ExecutionOn              DATETIME          NOT NULL
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

        IF OBJECT_ID('tempdb..#ClaimDetails') IS NOT NULL DROP TABLE #ClaimDetails;

        ;WITH InsLkp AS
        (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisInsID ORDER BY RowUpdateDateTime DESC) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[MisIns_Main]
        ),
        FinClassLkp AS
        (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisFinClassID ORDER BY RowUpdateDateTime DESC) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[MisFinClass_Main]
        ),
        FacLkp AS
        (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisFacID ORDER BY RowUpdateDateTime DESC) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[MisFac_Main]
        ),
        BusUnitLkp AS
        (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisBusUnitID ORDER BY RowUpdateDateTime DESC) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[MisBusUnit_Main]
        ),
        ClaimFormatLkp AS
        (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY BarClaimFormatID ORDER BY RowUpdateDateTime DESC) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[BarClaimFormat_Main]
        ),
        RegAcctBase AS
        (
            SELECT
                *,
                ROW_NUMBER() OVER
                (
                    PARTITION BY SourceID, VisitID
                    ORDER BY RowUpdateDateTime DESC, CreatedDateTime DESC
                ) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[RegAcct_Main]
        ),
        LatestClaim AS
        (
            SELECT
                *,
                ROW_NUMBER() OVER
                (
                    PARTITION BY SourceID, BarAcctClaimID
                    ORDER BY RowUpdateDateTime DESC
                ) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[BarAcctClaim_Main]
        ),
        ClaimVersion AS
        (
            SELECT
                *,
                ROW_NUMBER() OVER
                (
                    PARTITION BY SourceID, BarAcctClaimID
                    ORDER BY VersionID DESC, RowUpdateDateTime DESC
                ) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[BarAcctClaim_Versions]
        ),
        ClaimLines AS
        (
            SELECT
                SourceID,
                BarAcctClaimID,
                VersionID,
                COUNT(*) AS LineCount
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[BarAcctClaim_LineFlds]
            GROUP BY
                SourceID,
                BarAcctClaimID,
                VersionID
        ),
        LineTxns AS
        (
            SELECT
                SourceID,
                BarAcctClaimID,
                VersionID,
                COUNT(*) AS LineTransactionCount,
                SUM(TransactionNonCoverageAmount) AS LineTransactionTotal
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[BarAcctClaim_LineTxns]
            GROUP BY
                SourceID,
                BarAcctClaimID,
                VersionID
        ),
        BillAgg AS
        (
            SELECT
                SourceID,
                BarAccountOid_RegAcctID,
                SUM(TotalCharges) AS BillTotalCharges,
                COUNT(*) AS BillCount,
                MIN(FirstTransactionDate) AS FirstTransactionDate,
                MAX(LastTransactionDate) AS LastTransactionDate
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[BarAcctBill_Main]
            WHERE TotalCharges IS NOT NULL
               OR FirstTransactionDate IS NOT NULL
               OR LastTransactionDate IS NOT NULL
            GROUP BY
                SourceID,
                BarAccountOid_RegAcctID
        )

        SELECT
            cl.SourceID,
            r.PatientID,
            r.VisitID,
            hm.EmrNumber,
            hm.MultipleDepartmentMedicalRecordNumber,
            r.AccountNumber,
            CONCAT(hm.NameFirst, ' ', hm.NameMiddle, ' ', hm.NameLast) AS Name,
            hm.Birthdate,
            hm.Age,
            hm.Sex,
            hm.SocialSecurityNumber,
            hm.HealthCareNumber,
            r.RegistrationStatus,
            r.AdmitDateTime,
            r.ServiceDateTime,

            cl.BarAcctClaimID AS ClaimID,
            cl.ClaimDate,
            cl.DetailFromDate,
            cl.DetailThroughDate,
            cl.BillNumber,

            cl.Claim_BarClaimFormatID AS ClaimFormatID,
            cf.Name AS ClaimFormatName,

            cl.ClaimInsurance_MisInsID AS ClaimInsuranceID,
            mi.Name AS ClaimInsuranceName,
            fin.Name AS FinancialClassName,

            cl.Facility_MisFacID AS FacilityID,
            fa.Name AS FacilityName,
            cl.BusUnit_MisBusUnitID AS BusUnitID,
            bu.Name AS BusUnitName,

            cv.VersionID,
            cv.VersionType,
            cv.ClaimTotalCharges,
            cv.TotalCoveredAncillary,
            cv.TotalNonCoveredAncillary,
            cv.TotalCoveredRoom,
            cv.TotalNonCoveredRoom,

            ba.BillTotalCharges,
            ba.BillCount,
            cln.LineCount,
            lt.LineTransactionCount,
            lt.LineTransactionTotal,

            ba.FirstTransactionDate,
            ba.LastTransactionDate,

            COALESCE(cl.RowUpdateDateTime, cv.RowUpdateDateTime) AS RowUpdateDateTime
        INTO #ClaimDetails
        FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[BarAcctClaim_Main] AS cl

        INNER JOIN RegAcctBase r
            ON cl.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               r.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cl.BarAccountOid_RegAcctID COLLATE SQL_Latin1_General_CP1_CI_AS =
               r.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND r.rn = 1

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[HimRec_Main] AS hm
            ON hm.SourceID  = r.SourceID
           AND hm.PatientID = r.PatientID

        LEFT JOIN ClaimVersion cv
            ON cl.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               cv.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cl.BarAcctClaimID COLLATE SQL_Latin1_General_CP1_CI_AS =
               cv.BarAcctClaimID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cv.rn = 1

        LEFT JOIN ClaimLines cln
            ON cl.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               cln.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cl.BarAcctClaimID COLLATE SQL_Latin1_General_CP1_CI_AS =
               cln.BarAcctClaimID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cv.VersionID = cln.VersionID

        LEFT JOIN LineTxns lt
            ON cl.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               lt.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cl.BarAcctClaimID COLLATE SQL_Latin1_General_CP1_CI_AS =
               lt.BarAcctClaimID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cv.VersionID = lt.VersionID

        LEFT JOIN BillAgg ba
            ON r.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               ba.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND r.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS =
               ba.BarAccountOid_RegAcctID COLLATE SQL_Latin1_General_CP1_CI_AS

        LEFT JOIN ClaimFormatLkp cf
            ON cl.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               cf.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cl.Claim_BarClaimFormatID COLLATE SQL_Latin1_General_CP1_CI_AS =
               cf.BarClaimFormatID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cf.rn = 1

        LEFT JOIN InsLkp mi
            ON cl.ClaimInsurance_MisInsID COLLATE SQL_Latin1_General_CP1_CI_AS =
               mi.MisInsID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND mi.rn = 1

        LEFT JOIN FinClassLkp fin
            ON mi.FinancialClass_MisFinClassID COLLATE SQL_Latin1_General_CP1_CI_AS =
               fin.MisFinClassID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND fin.rn = 1

        LEFT JOIN FacLkp fa
            ON cl.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               fa.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cl.Facility_MisFacID COLLATE SQL_Latin1_General_CP1_CI_AS =
               fa.MisFacID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND fa.rn = 1

        LEFT JOIN BusUnitLkp bu
            ON cl.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               bu.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cl.BusUnit_MisBusUnitID COLLATE SQL_Latin1_General_CP1_CI_AS =
               bu.MisBusUnitID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND bu.rn = 1

        WHERE COALESCE(
                cl.ClaimDate,
                cl.RowUpdateDateTime
              ) >= @WindowStart
          AND COALESCE(
                cl.ClaimDate,
                cl.RowUpdateDateTime
              ) < @WindowEndNextDay;

        INSERT INTO dbo.tbl_FCAP1A_ClaimsData
        (
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
            ClaimID,
            ClaimDate,
            DetailFromDate,
            DetailThroughDate,
            BillNumber,
            ClaimFormatID,
            ClaimFormatName,
            ClaimInsuranceID,
            ClaimInsuranceName,
            FinancialClassName,
            FacilityID,
            FacilityName,
            BusUnitID,
            BusUnitName,
            VersionID,
            VersionType,
            ClaimTotalCharges,
            TotalCoveredAncillary,
            TotalNonCoveredAncillary,
            TotalCoveredRoom,
            TotalNonCoveredRoom,
            BillTotalCharges,
            BillCount,
            LineCount,
            LineTransactionCount,
            LineTransactionTotal,
            FirstTransactionDate,
            LastTransactionDate,
            RowUpdateDateTime,
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
            c.ClaimID,
            c.ClaimDate,
            c.DetailFromDate,
            c.DetailThroughDate,
            c.BillNumber,
            c.ClaimFormatID,
            c.ClaimFormatName,
            c.ClaimInsuranceID,
            c.ClaimInsuranceName,
            c.FinancialClassName,
            c.FacilityID,
            c.FacilityName,
            c.BusUnitID,
            c.BusUnitName,
            c.VersionID,
            c.VersionType,
            c.ClaimTotalCharges,
            c.TotalCoveredAncillary,
            c.TotalNonCoveredAncillary,
            c.TotalCoveredRoom,
            c.TotalNonCoveredRoom,
            c.BillTotalCharges,
            c.BillCount,
            c.LineCount,
            c.LineTransactionCount,
            c.LineTransactionTotal,
            c.FirstTransactionDate,
            c.LastTransactionDate,
            c.RowUpdateDateTime,
            @SourceTableList AS SourceTable,
            @RunStart        AS ExecutionOn
        FROM #Cohort AS cohort
        INNER JOIN #ClaimDetails AS c
            ON cohort.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
             = c.PatientID     COLLATE SQL_Latin1_General_CP1_CI_AS;

        CREATE NONCLUSTERED INDEX IX_tbl_FCAP1A_ClaimsData_Patient
            ON dbo.tbl_FCAP1A_ClaimsData (PatientID);

        CREATE NONCLUSTERED INDEX IX_tbl_FCAP1A_ClaimsData_Claim
            ON dbo.tbl_FCAP1A_ClaimsData (ClaimID, ClaimDate);

        CREATE NONCLUSTERED INDEX IX_tbl_FCAP1A_ClaimsData_Visit
            ON dbo.tbl_FCAP1A_ClaimsData (VisitID);

        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_ClaimsData;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
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
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            N'ClaimsData',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            @RecordCount,
            SYSTEM_USER,
            NULL,
            N'Claim records from BarAcctClaim_Main/Versions/LineFlds/LineTxns and BarAcctBill_Main with full identity keys and demographics enrichment.'
        );

        PRINT 'ClaimsData complete. Rows: ' + CAST(@RecordCount AS VARCHAR(20));

    END TRY
    BEGIN CATCH

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
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
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'FAILED',
            N'ClaimsData',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            NULL,
            SYSTEM_USER,
            @Err,
            N'Error during ClaimsData rebuild.'
        );

        THROW;

    END CATCH;
END;
GO
