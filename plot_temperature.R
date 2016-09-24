#install.packages("lubridate")
library(data.table)
library(lubridate)
library(ggplot2)
# devtools::install_github('Ather-Energy/ggTimeSeries')
library(ggTimeSeries)
library(RColorBrewer)

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

# https://datamarket.azure.com/dataset/datagovuk/metofficeweatheropendata
# limit ID > 5300088 & site name == BENSON (3658)
# https://api.datamarket.azure.com/DataGovUK/MetOfficeWeatherOpenData/v1/Observation?$filter=ID%20gt%205300000L%20and%20SiteName%20eq%20%27BENSON%20(3658)%27

# Load primary account key
source("config.R")

external.temperature <- fread(paste0("https://datamarket.azure.com/offer/download?endpoint=https%3A%2F%2Fapi.datamarket.azure.com%2FDataGovUK%2FMetOfficeWeatherOpenData%2Fv1%2F&query=Observation%3F%24filter%3DID%2520gt%25205300000L%2520and%2520SiteName%2520eq%2520%2527BENSON%2520(3658)%2527&accountKey=",api.key,"&title=UK+Met+Office+Weather+Open+Data&name=UK+Met+Office+Weather+Open+Data-Observation"))

external.temperature$ObservationDate <- substr(external.temperature$ObservationDate, 0, 10)
external.temperature$ObservationTime2 <- ymd_h(paste(external.temperature$ObservationDate, external.temperature$ObservationTime))

# subset
external.temperature <- external.temperature[, .("time" = ObservationTime2, "temperature" = ScreenTemperature, "source" = "Outside Temperature (RAF Benson)", batch = NA)]

# 
external.temperature <- external.temperature[time %within% interval(min(internal.temperature$time), max(internal.temperature$time))]

temperature <- rbind(internal.temperature, external.temperature)
temperature$temperature <- as.numeric(temperature$temperature)

# remove outlier data points (-99.00)
temperature <- temperature[temperature > (-30)]

# Remove anomylous points when data logger was plugged into laptop
outliers <- temperature[time %within% interval(ymd_hms("2016-04-12 17:40:00"), ymd_hms("2016-04-12 18:10:00"))
                        | time %within% interval(ymd_hms("2016-07-20 17:40:00"), ymd_hms("2016-07-20 19:20:00"))
                        | time %within% interval(ymd_hms("2016-07-26 23:21:00"), ymd_hms("2016-07-27 01:25:00"))
                        | time %within% interval(ymd_hms("2016-07-28 19:10:00"), ymd_hms("2016-07-28 19:25:00"))]

temperature <- temperature[!time %within% interval(ymd_hms("2016-04-12 17:40:00"), ymd_hms("2016-04-12 18:10:00"))
                           & !time %within% interval(ymd_hms("2016-07-20 17:40:00"), ymd_hms("2016-07-20 19:20:00"))
                           & !time %within% interval(ymd_hms("2016-07-26 23:21:00"), ymd_hms("2016-07-27 01:25:00"))
                           & !time %within% interval(ymd_hms("2016-07-28 19:10:00"), ymd_hms("2016-07-28 19:25:00"))]

# recursively remove outliers (when diff in consequtive temperatures >0.19)
# temperature[source == "Inside Temperature", diff := c(NA, diff(temperature))]
# nrow(temperature[abs(diff) > 0.2])
# temperature <- temperature[abs(diff) < 0.2]
# plot(temperature$diff)

# plot
png("plots/temperature.png", width = 900, height = 450)
ggplot(temperature, aes(time, temperature, group = source, colour = source)) + 
  geom_line() + 
  theme_minimal() +
  scale_x_datetime(date_minor_breaks = "1 day") +  
  scale_y_continuous(breaks = seq(-5,27,2)) +
  theme(legend.position = "bottom") +
  labs(x = "", y = "Temperature (°C)")
dev.off()

png("plots/temperature_calendar.png", width = 900, height = 450)
ggplot_calendar_heatmap(temperature[source=="Inside Temperature"], 'time', 'temperature') +
  scale_fill_distiller(palette = 'RdBu')
# facet_wrap(~Year, ncol = 1) # for when there's more than one year of data
dev.off()

# set dat month year to the same for all point so can calculate daily fluctuation
temperature$time.only <- as.POSIXct(strftime(temperature$time, format = "%H:%M:%S"), format = "%H:%M:%S")

# assign each data point to an interval
temperature$interval <- as.POSIXct(cut(temperature$time.only, "30 mins"))

# caclulate mean
daily.temperature <- temperature[, .(mean.temp=mean(temperature)), by = list(source, interval)]

# plot average daily pattern
png("plots/daily_temperature.png", width = 900, height = 450)
ggplot(daily.temperature, aes(interval, mean.temp, group = source, colour = source)) + 
  geom_line() + 
  theme_minimal() +
  scale_x_datetime(date_labels = "%H:%M") +
  theme(legend.position = "bottom") +
  labs(x = "Time", y = "Mean Temperature (°C)")
dev.off()

# zero-mean and scale to standard variance
daily.temperature[source=="Inside Temperature", scaled.temp := scale(mean.temp)]
daily.temperature[source=="Outside Temperature (RAF Benson)", scaled.temp := scale(mean.temp)]

png("plots/daily_temperature_scaled.png", width = 900, height = 450)
ggplot(daily.temperature, aes(interval, scaled.temp, group = source, colour = source)) + 
  geom_line() + 
  theme_minimal() +
  scale_x_datetime(date_labels = "%H:%M") +
  theme(legend.position = "bottom") +
  labs(x = "Time", y = "Mean Temperature (°C)")
dev.off()

# plot all temp points over a single day timeframe
ggplot(temperature[source=="Inside Temperature"], aes(time.only, temperature, group = source, colour = source)) + 
  geom_point(alpha = 0.1)

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

