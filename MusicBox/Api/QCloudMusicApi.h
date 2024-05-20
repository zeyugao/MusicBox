//
//  QCloudMusicApi.c
//  MusicBox
//
//  Created by Elsa on 2024/5/2.
//

#ifndef QCLOUDMUSIC_H
#define QCLOUDMUSIC_H

int invoke(char *memberName, char *value);
char *get_result(int key);
void free_result(int key);
char *memberName(int i);
int memberCount();

#endif
