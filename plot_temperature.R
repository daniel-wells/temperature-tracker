#install.packages("lubridate")
library(data.table)
library(lubridate)
library(ggplot2)
library(zoo) # for interpolation
# devtools::install_github('Ather-Energy/ggTimeSeries')
library(ggTimeSeries) # for weekly heatmap
library(RColorBrewer)

######################################################
############ LOAD AND CLEAN INTERNAL TEMPERATURE
######################################################

clean.file <- function(data){
  # remove empty columns
  data$No. <- NULL
  data$V2 <- NULL
  data$Time <- NULL
  data$"Temperature°C     Humidity%RH" <- NULL
  data$V7 <- NULL
  
  setnames(data, c("time","temperature"))
  
  # convert time to POSIXct
  data$time <- ymd_hms(data$time)
  
  # remove first 15 readings (to remove temperature spike at start)
  data <- data[-c(1:15)]
  return(data)
}

data.files <- list.files(path = "data", pattern = "temperature[0-9]+.tsv")
stopifnot(length(data.files) > 0)

internal.temperature <- data.table()
i = 0
for (file in data.files){
  i <- i+1
  temp <- clean.file(fread(paste0("data/",file)))
  temp$batch = i
  internal.temperature <- rbind(internal.temperature, temp)
}

internal.temperature$source <- "Inside Temperature"

# overwrite anomylous temperatures when data logger was plugged into laptop
internal.temperature[time %within% interval(ymd_hms("2016-04-12 17:40:00"), ymd_hms("2016-04-12 18:10:00"))]$temperature <- 22.0
internal.temperature[time %within% interval(ymd_hms("2016-07-20 17:40:00"), ymd_hms("2016-07-20 19:20:00"))]$temperature <- 26.4
internal.temperature[time %within% interval(ymd_hms("2016-07-26 23:21:00"), ymd_hms("2016-07-27 01:25:00"))]$temperature <- 24.8
internal.temperature[time %within% interval(ymd_hms("2016-07-28 19:10:00"), ymd_hms("2016-07-28 19:25:00"))]$temperature <- 24.6

# recursively remove outliers (when diff in consequtive temperatures >0.19)
# temperature[source == "Inside Temperature", diff := c(NA, diff(temperature))]
# nrow(temperature[abs(diff) > 0.2])
# temperature <- temperature[abs(diff) < 0.2]
# plot(temperature$diff)

######################################################
############ LOAD AND CLEAN EXTERNAL TEMPERATURE
######################################################

# https://datamarket.azure.com/dataset/datagovuk/metofficeweatheropendata
# limit ID > 5300088 & site name == BENSON (3658)
# https://api.datamarket.azure.com/DataGovUK/MetOfficeWeatherOpenData/v1/Observation?$filter=ID%20gt%205300000L%20and%20SiteName%20eq%20%27BENSON%20(3658)%27

# Load primary account key
source("config.R")

external.temperature <- fread(paste0("https://datamarket.azure.com/offer/download?endpoint=https%3A%2F%2Fapi.datamarket.azure.com%2FDataGovUK%2FMetOfficeWeatherOpenData%2Fv1%2F&query=Observation%3F%24filter%3DID%2520gt%25205300000L%2520and%2520SiteName%2520eq%2520%2527BENSON%2520(3658)%2527&accountKey=",api.key,"&title=UK+Met+Office+Weather+Open+Data&name=UK+Met+Office+Weather+Open+Data-Observation"))

# extract date
external.temperature$ObservationDate <- substr(external.temperature$ObservationDate, 0, 10)
external.temperature$ObservationTime2 <- ymd_h(paste(external.temperature$ObservationDate, external.temperature$ObservationTime))

# subset columns
external.temperature <- external.temperature[, .("time" = ObservationTime2, "temperature" = as.numeric(ScreenTemperature), "source" = "Outside Temperature (RAF Benson)", batch = NA)]

# time to within the internal temperature range
external.temperature <- external.temperature[time %within% interval(min(internal.temperature$time), max(internal.temperature$time))]

# some missing data & some duplicates

# remove outlier data points (-99.00), temperature[temperature < (-30)]
external.temperature[temperature < (-30)]$temperature <- NA

# remove duplicates
duplicates <- which(duplicated(external.temperature, by = "time")==T)
external.temperature[duplicates]$temperature <- 9999
external.temperature <- external.temperature[!temperature == 9999]

# correct missing data
missing.indexes <- which(diff(external.temperature$time) != 1)
missing.times <- external.temperature[missing.indexes]$time + hms("01:00:00")
missing.rows <- data.table(batch = NA, source = "Outside Temperature (RAF Benson)", time = missing.times, temperature = NA)

external.temperature <- rbind(external.temperature, missing.rows)
external.temperature <- external.temperature[order(time)]

# interpolate missing temperatures
external.temperature$temperature <- na.spline(external.temperature$temperature)

# remove a day (too much missing to impute)
external.temperature <- external.temperature[!time %within% interval(ymd_hms("2016-03-19 00:00:00"), ymd_hms("2016-03-19 23:59:59"))]

#########################################################
######### combine inside and outside datasets & analyse
#########################################################
temperature <- rbind(internal.temperature, external.temperature)
temperature$temperature <- as.numeric(temperature$temperature)


# plot
png("plots/temperature.png", width = 900, height = 450)
ggplot(temperature, aes(time, temperature, group = source, colour = source)) + 
  geom_line() + 
  theme_minimal() +
  scale_x_datetime(date_minor_breaks = "1 day") +  
  scale_y_continuous(breaks = seq(-4,32,2)) +
  theme(legend.position = "bottom") +
  labs(x = "", y = "Temperature (°C)")
dev.off()

png("plots/temperature_calendar.png", width = 900, height = 450)
ggplot_calendar_heatmap(temperature[source=="Inside Temperature"], 'time', 'temperature') +
  theme(legend.position = "bottom") +
  scale_fill_distiller(palette = 'RdBu')
# facet_wrap(~Year, ncol = 1) # for when there's more than one year of data
dev.off()

# trim to make data point frequency even throughout
trimmed <- rbind(temperature[source == "Inside Temperature" & batch==1][1:9755],
            temperature[source == "Inside Temperature" & batch==1][10446:31985],
            temperature[source == "Inside Temperature" & batch==2][178:31881],
            temperature[source == "Inside Temperature" & batch==3],
            temperature[source == "Outside Temperature (RAF Benson)"])

# create time series objects
inside.ts <- ts(trimmed[source == "Inside Temperature"]$temperature, frequency = 720)
outside.ts <- ts(trimmed[source == "Outside Temperature (RAF Benson)"]$temperature, frequency = 24)

# seperate daily cycle from overall trend
decomp.outside <- decompose(outside.ts, type="multiplicative")
decomp.inside <- decompose(inside.ts, type="multiplicative")

# stl.outside <- stl(log(outside.ts+10), s.window="periodic")

# add seasonally adjusted values back
# shoud really be decomp.inside$trend * decomp.inside$random
trimmed[source == "Outside Temperature (RAF Benson)", trend := scale(decomp.outside$trend)[,1]]
trimmed[source == "Outside Temperature (RAF Benson)", seasonal := scale(as.numeric(decomp.outside$seasonal))[,1]]

trimmed[source == "Inside Temperature", trend := scale(decomp.inside$trend)[,1]]
trimmed[source == "Inside Temperature", seasonal := scale(as.numeric(decomp.inside$seasonal))[,1]]

# Ongoing Trend
png("plots/co_trend.png", width = 900, height = 450)
ggplot(trimmed, aes(time, trend, group = source, colour = source)) + 
  geom_line() +
  theme_minimal() +
  theme(legend.position = "bottom") +
  labs(x = "Time", y = "Scaled Temperature (°C)")
dev.off()

# Daily Cycles
png("plots/daily_cycle.png", width = 900, height = 450)
ggplot(trimmed[time %within% interval(ymd_hms("2016-04-15 00:00:00"), ymd_hms("2016-04-15 23:59:59"))], aes(time, seasonal, group = source, colour = source)) + 
  geom_line() +
  scale_x_datetime(date_labels = "%H:%M") +
  theme_minimal() +
  theme(legend.position = "bottom") +
  labs(x = "Time", y = "Scaled Temperature (°C)")
dev.off()


# calculate daily averages
temperature$day.only <- strftime(temperature$time, format = "%Y-%m-%d")
temp.byday <- temperature[, .(mean.temp = mean(temperature)), by = c("day.only", "source")]

# match up inside and outside temp by day
temp.byday.inside <- temp.byday[source == "Inside Temperature"]
temp.byday.outside <- temp.byday[source == "Outside Temperature (RAF Benson)"]
setkey(temp.byday.inside, day.only)
setkey(temp.byday.outside, day.only)
temp.byday <- temp.byday.outside[temp.byday.inside]

# plot inside vs outside mean temp
png("plots/temperature_regression.png", width = 900, height = 450)
ggplot(temp.byday, aes(mean.temp, i.mean.temp)) + 
  geom_point() +
  theme_minimal() +
  labs(x = "Mean Outside Temperature (°C)", y = "Mean Inside Temperature (°C)")
dev.off()

